//! 经 `SendInput` 注入鼠标与键盘。坐标是主屏物理像素，调用线程要先 `dpi::per_monitor_thread`。
//! shortcut: UAC 等安全桌面上的窗口收不到注入，要支持时改由宿主注入。

use crate::input::{self, Injector, Key};
use macvm_agent_protocol::{InputEvent, MouseButton};
use std::io;
use std::mem::size_of;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSE_EVENT_FLAGS,
    MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT, SendInput,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN};

/// 一格滚轮的量（`WHEEL_DELTA`）。
const WHEEL_DELTA: i32 = 120;

pub fn play(events: &[InputEvent]) -> io::Result<()> {
    input::play(&mut Injection, events)
}

struct Injection;

fn send(inputs: &[INPUT]) -> io::Result<()> {
    // SAFETY: inputs 是有效的 INPUT 数组，大小如实传入。
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::PermissionDenied, "输入被系统拦截：目标窗口的权限更高，或当前在安全桌面上"))
    }
}

fn mouse(x: i32, y: i32, flags: MOUSE_EVENT_FLAGS, data: i32) -> INPUT {
    // SAFETY: 只查询虚拟桌面的范围。
    let (vx, vy, vw, vh) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2),
            GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2),
        )
    };
    let scale = |v: i32, origin: i32, extent: i32| ((i64::from(v - origin) * 65535) / i64::from(extent - 1)) as i32;
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: scale(x, vx, vw),
                dy: scale(y, vy, vh),
                mouseData: data as u32,
                dwFlags: flags | MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn keyboard(vk: u16, scan: u16, flags: u32) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

impl Injector for Injection {
    fn move_to(&mut self, x: i32, y: i32) -> io::Result<()> {
        send(&[mouse(x, y, 0, 0)])
    }

    fn button(&mut self, button: MouseButton, down: bool, x: i32, y: i32, _clicks: u32) -> io::Result<()> {
        let flags = match (button, down) {
            (MouseButton::Left, true) => MOUSEEVENTF_LEFTDOWN,
            (MouseButton::Left, false) => MOUSEEVENTF_LEFTUP,
            (MouseButton::Right, true) => MOUSEEVENTF_RIGHTDOWN,
            (MouseButton::Right, false) => MOUSEEVENTF_RIGHTUP,
            (MouseButton::Middle, true) => MOUSEEVENTF_MIDDLEDOWN,
            (MouseButton::Middle, false) => MOUSEEVENTF_MIDDLEUP,
        };
        send(&[mouse(x, y, flags, 0)])
    }

    fn scroll(&mut self, x: i32, y: i32, dx: i32, dy: i32) -> io::Result<()> {
        // 竖直滚轮正值向上，水平滚轮正值向右。
        let mut inputs = Vec::new();
        if dy != 0 {
            inputs.push(mouse(x, y, MOUSEEVENTF_WHEEL, -dy * WHEEL_DELTA));
        }
        if dx != 0 {
            inputs.push(mouse(x, y, MOUSEEVENTF_HWHEEL, dx * WHEEL_DELTA));
        }
        send(&inputs)
    }

    fn key(&mut self, key: Key, down: bool) -> io::Result<()> {
        let (vk, extended) = virtual_key(key).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("Windows 上没有这个键：{key:?}")))?;
        let mut flags = if down { 0 } else { KEYEVENTF_KEYUP };
        if extended {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        send(&[keyboard(vk, 0, flags)])
    }

    fn text(&mut self, text: &str) -> io::Result<()> {
        let mut inputs = Vec::new();
        for c in text.chars() {
            if c == '\n' {
                inputs.extend([keyboard(0x0D, 0, 0), keyboard(0x0D, 0, KEYEVENTF_KEYUP)]);
                continue;
            }
            let mut units = [0u16; 2];
            for &unit in c.encode_utf16(&mut units).iter() {
                inputs.extend([keyboard(0, unit, KEYEVENTF_UNICODE), keyboard(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)]);
            }
        }
        send(&inputs)
    }
}

/// 虚拟键码，以及是否是要带扩展标志的导航键。
fn virtual_key(key: Key) -> Option<(u16, bool)> {
    Some(match key {
        Key::Cmd => (0x5B, true),
        Key::Ctrl => (0x11, false),
        Key::Alt => (0x12, false),
        Key::Shift => (0x10, false),
        Key::Enter => (0x0D, false),
        Key::Tab => (0x09, false),
        Key::Escape => (0x1B, false),
        Key::Space => (0x20, false),
        Key::Backspace => (0x08, false),
        Key::Delete => (0x2E, true),
        Key::PageUp => (0x21, true),
        Key::PageDown => (0x22, true),
        Key::End => (0x23, true),
        Key::Home => (0x24, true),
        Key::Left => (0x25, true),
        Key::Up => (0x26, true),
        Key::Right => (0x27, true),
        Key::Down => (0x28, true),
        Key::F(n @ 1..=12) => (0x6F + u16::from(n), false),
        Key::F(_) => return None,
        Key::Char(c @ ('a'..='z' | '0'..='9')) => (c.to_ascii_uppercase() as u16, false),
        Key::Char(c) => {
            let vk = match c {
                ';' => 0xBA,
                '=' => 0xBB,
                ',' => 0xBC,
                '-' => 0xBD,
                '.' => 0xBE,
                '/' => 0xBF,
                '`' => 0xC0,
                '[' => 0xDB,
                '\\' => 0xDC,
                ']' => 0xDD,
                '\'' => 0xDE,
                _ => return None,
            };
            (vk, false)
        }
    })
}
