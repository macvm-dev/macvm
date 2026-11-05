//! 经 `/dev/uinput` 建一个虚拟键盘和一个绝对坐标指针（与 QEMU usb-tablet 同类），X11 与 Wayland 都认。要 root。

use crate::input::{self, Injector, Key};
use macvm_agent_protocol::{InputEvent, MouseButton};
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

const fn ui_iow(nr: u32, size: usize) -> libc::c_ulong {
    ((1 << 30) | ((size as u32) << 16) | (0x55 << 8) | nr) as libc::c_ulong
}

const UI_DEV_CREATE: libc::c_ulong = 0x5501;
const UI_DEV_SETUP: libc::c_ulong = ui_iow(3, size_of::<Setup>());
const UI_ABS_SETUP: libc::c_ulong = ui_iow(4, size_of::<AbsSetup>());
const UI_SET_EVBIT: libc::c_ulong = ui_iow(100, 4);
const UI_SET_KEYBIT: libc::c_ulong = ui_iow(101, 4);
const UI_SET_RELBIT: libc::c_ulong = ui_iow(102, 4);
const UI_SET_ABSBIT: libc::c_ulong = ui_iow(103, 4);

const EV_SYN: u16 = 0;
const EV_KEY: u16 = 1;
const EV_REL: u16 = 2;
const EV_ABS: u16 = 3;
const SYN_REPORT: u16 = 0;
const ABS_X: u16 = 0;
const ABS_Y: u16 = 1;
const REL_HWHEEL: u16 = 6;
const REL_WHEEL: u16 = 8;
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const BUS_VIRTUAL: u16 = 0x06;

#[repr(C)]
struct Setup {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [u8; 80],
    ff_effects_max: u32,
}

#[repr(C)]
struct AbsSetup {
    code: u16,
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
}

#[repr(C)]
struct Event {
    sec: i64,
    usec: i64,
    kind: u16,
    code: u16,
    value: i32,
}

fn ioctl_ptr<T>(file: &File, request: libc::c_ulong, arg: &T) -> io::Result<()> {
    // SAFETY: arg 是与 request 对应、按内核布局定义的结构体。
    if unsafe { libc::ioctl(file.as_raw_fd(), request as _, arg as *const T) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

fn ioctl_int(file: &File, request: libc::c_ulong, value: u16) -> io::Result<()> {
    // SAFETY: UI_SET_*BIT 按值接收一个整数。
    if unsafe { libc::ioctl(file.as_raw_fd(), request as _, libc::c_int::from(value)) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

fn open_uinput() -> io::Result<File> {
    let open = || OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open("/dev/uinput");
    match open() {
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            crate::run("modprobe", &["uinput"])?;
            open()
        }
        other => other,
    }
}

fn create(name: &str, product: u16, configure: impl FnOnce(&File) -> io::Result<()>) -> io::Result<File> {
    let file = open_uinput()?;
    configure(&file)?;
    let mut setup = Setup { bustype: BUS_VIRTUAL, vendor: 0x1af4, product, version: 1, name: [0; 80], ff_effects_max: 0 };
    setup.name[..name.len()].copy_from_slice(name.as_bytes());
    ioctl_ptr(&file, UI_DEV_SETUP, &setup)?;
    // SAFETY: UI_DEV_CREATE 不带参数。
    if unsafe { libc::ioctl(file.as_raw_fd(), UI_DEV_CREATE as _) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

struct Devices {
    keyboard: File,
    pointer: File,
}

/// 指针设备的坐标范围 0…`ABS_RANGE`，合成器把它映射到整个屏幕；注入时按当时的屏幕尺寸换算，分辨率变了不用重建设备。
const ABS_RANGE: i32 = 32767;

impl Devices {
    fn new() -> io::Result<Self> {
        let keyboard = create("MacVM Keyboard", 1, |f| {
            ioctl_int(f, UI_SET_EVBIT, EV_KEY)?;
            (1..=255).try_for_each(|code| ioctl_int(f, UI_SET_KEYBIT, code))
        })?;
        let pointer = create("MacVM Tablet", 2, |f| {
            ioctl_int(f, UI_SET_EVBIT, EV_KEY)?;
            for button in [BTN_LEFT, BTN_RIGHT, BTN_MIDDLE] {
                ioctl_int(f, UI_SET_KEYBIT, button)?;
            }
            ioctl_int(f, UI_SET_EVBIT, EV_REL)?;
            ioctl_int(f, UI_SET_RELBIT, REL_WHEEL)?;
            ioctl_int(f, UI_SET_RELBIT, REL_HWHEEL)?;
            ioctl_int(f, UI_SET_EVBIT, EV_ABS)?;
            for code in [ABS_X, ABS_Y] {
                ioctl_int(f, UI_SET_ABSBIT, code)?;
                let abs = AbsSetup { code, value: 0, minimum: 0, maximum: ABS_RANGE, fuzz: 0, flat: 0, resolution: 0 };
                ioctl_ptr(f, UI_ABS_SETUP, &abs)?;
            }
            Ok(())
        })?;
        // 合成器经 udev 发现新设备要一会儿，之前注入的事件会丢。
        thread::sleep(SETTLE);
        Ok(Self { keyboard, pointer })
    }
}

/// 每个按键事件之后的停顿：连续事件挤在一起时，合成器会丢掉修饰键之后的按键。
const KEY_PAUSE: Duration = Duration::from_millis(8);

/// 新建设备后等合成器接上的时间。
const SETTLE: Duration = Duration::from_secs(1);

static DEVICES: Mutex<Option<Devices>> = Mutex::new(None);

fn with_devices<T>(f: impl FnOnce(&mut Devices) -> io::Result<T>) -> io::Result<T> {
    let mut devices = DEVICES.lock().unwrap_or_else(|e| e.into_inner());
    if devices.is_none() {
        *devices = Some(Devices::new()?);
    }
    f(devices.as_mut().expect("刚建好"))
}

/// 先建好虚拟设备：图形会话在它之后启动时一开始就认得它，第一次注入不必等合成器。
pub fn prepare() -> io::Result<()> {
    with_devices(|_| Ok(()))
}

/// 按屏幕像素尺寸 `size` 注入。
pub fn play(size: (u32, u32), events: &[InputEvent]) -> io::Result<()> {
    with_devices(|devices| input::play(&mut Uinput { devices, size }, events))
}

struct Uinput<'a> {
    devices: &'a mut Devices,
    size: (u32, u32),
}

impl Uinput<'_> {
    fn abs(&self, x: i32, y: i32) -> [(u16, u16, i32); 2] {
        let scale = |v: i32, extent: u32| (i64::from(v) * i64::from(ABS_RANGE) / i64::from(extent.saturating_sub(1).max(1))) as i32;
        [(EV_ABS, ABS_X, scale(x, self.size.0)), (EV_ABS, ABS_Y, scale(y, self.size.1))]
    }
}

fn emit(device: &mut File, events: &[(u16, u16, i32)]) -> io::Result<()> {
    let mut bytes = Vec::with_capacity((events.len() + 1) * size_of::<Event>());
    for &(kind, code, value) in events.iter().chain([(EV_SYN, SYN_REPORT, 0)].iter()) {
        let event = Event { sec: 0, usec: 0, kind, code, value };
        // SAFETY: Event 是 repr(C) 的纯数据，按字节写给内核。
        bytes.extend_from_slice(unsafe { std::slice::from_raw_parts(&event as *const Event as *const u8, size_of::<Event>()) });
    }
    device.write_all(&bytes)
}

impl Injector for Uinput<'_> {
    fn move_to(&mut self, x: i32, y: i32) -> io::Result<()> {
        let at = self.abs(x, y);
        emit(&mut self.devices.pointer, &at)
    }

    fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, _clicks: u32) -> io::Result<()> {
        let code = match button {
            MouseButton::Left => BTN_LEFT,
            MouseButton::Right => BTN_RIGHT,
            MouseButton::Middle => BTN_MIDDLE,
        };
        let [ax, ay] = self.abs(x, y);
        emit(&mut self.devices.pointer, &[ax, ay, (EV_KEY, code, i32::from(down))])
    }

    fn scroll(&mut self, _x: i32, _y: i32, dx: i32, dy: i32) -> io::Result<()> {
        // 滚轮正值向上。
        emit(&mut self.devices.pointer, &[(EV_REL, REL_WHEEL, -dy), (EV_REL, REL_HWHEEL, dx)])
    }

    fn key(&mut self, key: Key, down: bool) -> io::Result<()> {
        let code = keycode(key).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("Linux 上没有这个键：{key:?}")))?;
        emit(&mut self.devices.keyboard, &[(EV_KEY, code, i32::from(down))])?;
        thread::sleep(KEY_PAUSE);
        Ok(())
    }

    fn text(&mut self, text: &str) -> io::Result<()> {
        input::type_ascii(self, text)
    }
}

/// evdev 键码（`KEY_*`），按美式布局。
fn keycode(key: Key) -> Option<u16> {
    Some(match key {
        Key::Cmd => 125,
        Key::Ctrl => 29,
        Key::Alt => 56,
        Key::Shift => 42,
        Key::Enter => 28,
        Key::Tab => 15,
        Key::Escape => 1,
        Key::Space => 57,
        Key::Backspace => 14,
        Key::Delete => 111,
        Key::Up => 103,
        Key::Down => 108,
        Key::Left => 105,
        Key::Right => 106,
        Key::Home => 102,
        Key::End => 107,
        Key::PageUp => 104,
        Key::PageDown => 109,
        Key::F(n @ 1..=10) => 58 + u16::from(n),
        Key::F(11) => 87,
        Key::F(12) => 88,
        Key::F(_) => return None,
        Key::Char(c) => {
            const ROWS: [(&str, u16); 4] = [("1234567890-=", 2), ("qwertyuiop[]", 16), ("asdfghjkl;'`", 30), ("\\zxcvbnm,./", 43)];
            ROWS.iter().find_map(|(row, first)| row.find(c).map(|i| first + i as u16))?
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_layouts() {
        assert_eq!(size_of::<Setup>(), 92);
        assert_eq!(size_of::<AbsSetup>(), 28);
        assert_eq!(size_of::<Event>(), 24);
        assert_eq!(UI_DEV_SETUP, 0x405c_5503);
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
    }

    #[test]
    fn evdev_keycodes() {
        assert_eq!(keycode(Key::Char('1')), Some(2));
        assert_eq!(keycode(Key::Char('=')), Some(13));
        assert_eq!(keycode(Key::Char('q')), Some(16));
        assert_eq!(keycode(Key::Char(']')), Some(27));
        assert_eq!(keycode(Key::Char('a')), Some(30));
        assert_eq!(keycode(Key::Char('`')), Some(41));
        assert_eq!(keycode(Key::Char('\\')), Some(43));
        assert_eq!(keycode(Key::Char('/')), Some(53));
        assert_eq!(keycode(Key::F(1)), Some(59));
        assert_eq!(keycode(Key::F(10)), Some(68));
    }
}
