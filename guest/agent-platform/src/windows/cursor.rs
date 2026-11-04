//! virtio-gpu 显卡驱动的硬件光标开关（驱动键下的 `HWCursor`，驱动启动时读取，INF 默认关）。
//! 只有 viogpudo 支持硬件光标；viogpu3d 不向 Windows 申报硬件光标能力，开关对它无效，光标总由 Windows 画进画面。
//!
//! 打开后 Windows 不再把光标画进画面，而是交给显卡：QEMU 的 virtio-gpu 把光标形状转给宿主，宿主用它作
//! 系统光标，跟手且无延迟；VZ 的 virtio-gpu 不显示硬件光标，打开后客户机里就看不到光标。
//! 同一台 Windows 在两种引擎下是不同的设备实例，各有自己的驱动键，所以只改当前在场的实例。
//!
//! viogpudo 换光标时先在控制队列上传图像、随即在光标队列上更新光标，不等上传完成；QEMU 先处理光标队列，
//! 拷到的总是上一个形状。所以光标形状由代理从客户机直接取（`watch_cursor`），不用 QEMU 转来的。
//!
//! 没有硬件光标时（QEMU 下的 viogpu3d），光标随客户机画面一起合成，比宿主光标慢几帧。推送期间代理把
//! 系统光标换成透明的，按句柄认出系统光标、推送它的种类，由宿主画；程序自带的光标仍由客户机画，
//! 那时推送「隐藏」。最后一个推送连接结束时恢复系统光标，代理启动时也先恢复一次（`restore_system_cursors`），
//! 免得上次被强行结束时留下透明光标。

use std::io;
use std::mem::{size_of, zeroed};
use std::ptr;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use windows_sys::Win32::Foundation::POINT;
use windows_sys::Win32::System::Registry::{KEY_QUERY_VALUE, KEY_SET_VALUE, REG_DWORD, RegCloseKey, RegQueryValueExW, RegSetValueExW};

use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAP, BITMAPINFO, BITMAPINFOHEADER, DIB_RGB_COLORS, DeleteObject, GetDC, GetDIBits, GetObjectW, HBITMAP, MONITOR_DEFAULTTOPRIMARY,
    MonitorFromPoint, ReleaseDC,
};
use windows_sys::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI, SetThreadDpiAwarenessContext};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CURSOR_SHOWING, CURSORINFO, CreateCursor, GetCursorInfo, GetIconInfo, HCURSOR, ICONINFO, LoadCursorW, OCR_APPSTARTING, OCR_CROSS, OCR_HAND,
    OCR_HELP, OCR_IBEAM, OCR_NO, OCR_NORMAL, OCR_SIZEALL, OCR_SIZENESW, OCR_SIZENS, OCR_SIZENWSE, OCR_SIZEWE, OCR_UP, OCR_WAIT, SPI_SETCURSORS,
    SYSTEM_CURSOR_ID, SetSystemCursor, SystemParametersInfoW,
};

use super::gpu::{for_each_present_virtio_gpu, is_3d_driver, on_vz, open_driver_key};
use super::wide;
use crate::{CursorImage, GuestCursor};

/// 本次开机驱动是否已在使用硬件光标（驱动只在启动时读开关）。
static HARDWARE_CURSOR_ACTIVE: AtomicBool = AtomicBool::new(false);
/// 轮询当前光标的间隔，即形状变化最多晚这么久到达宿主；位置由宿主自己画，不受影响。
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// 按所在引擎设好在场 virtio-gpu 的硬件光标开关；改动在下次开机生效。
pub fn configure_hardware_cursor() {
    let enable = !on_vz();
    for_each_present_virtio_gpu(|set, info| {
        let Some(key) = open_driver_key(set, info, KEY_QUERY_VALUE | KEY_SET_VALUE) else { return };
        let name = wide("HWCursor");
        let mut current: u32 = 0;
        let mut size = size_of::<u32>() as u32;
        // SAFETY: 缓冲区与长度一致；键在本闭包内关闭。
        unsafe {
            let read = RegQueryValueExW(key, name.as_ptr(), ptr::null(), ptr::null_mut(), (&mut current as *mut u32).cast(), &mut size);
            let wanted = u32::from(enable);
            if enable && read == 0 && current == 1 && !is_3d_driver(key) {
                HARDWARE_CURSOR_ACTIVE.store(true, Ordering::Relaxed);
            }
            if read != 0 || current != wanted {
                RegSetValueExW(key, name.as_ptr(), 0, REG_DWORD, (&wanted as *const u32).cast(), size_of::<u32>() as u32);
            }
            RegCloseKey(key);
        }
    });
}

/// 运行中换上了不支持硬件光标的驱动：此后光标由客户机画进画面，`watch_cursor` 随即结束。
pub(super) fn hardware_cursor_lost() {
    HARDWARE_CURSOR_ACTIVE.store(false, Ordering::Relaxed);
}

/// 光标变化时回调，回调出错或 `alive` 为假时返回。系统光标只推种类，由宿主换成自己的同类光标；
/// 用硬件光标时其余光标推图像，否则（QEMU 下的 viogpu3d）推送期间隐藏系统光标，其余光标仍由客户机画、推 `Hidden`。
/// VZ 下宿主不画光标，不提供。
pub fn watch_cursor(alive: impl Fn() -> bool, on_change: impl FnMut(GuestCursor) -> io::Result<()>) -> io::Result<()> {
    if HARDWARE_CURSOR_ACTIVE.load(Ordering::Relaxed) {
        watch_hardware_cursor(alive, on_change)
    } else if !on_vz() {
        watch_hidden_cursors(alive, on_change)
    } else {
        Err(io::Error::new(io::ErrorKind::Unsupported, "客户机自绘光标"))
    }
}

/// 硬件光标中途失效（换上了 viogpu3d）时返回错误，宿主重连后改走 `watch_hidden_cursors`。
fn watch_hardware_cursor(alive: impl Fn() -> bool, mut on_change: impl FnMut(GuestCursor) -> io::Result<()>) -> io::Result<()> {
    let system = system_cursor_handles();
    let mut last: Option<(HCURSOR, bool)> = None;
    while alive() {
        if !HARDWARE_CURSOR_ACTIVE.load(Ordering::Relaxed) {
            return Err(io::Error::new(io::ErrorKind::Unsupported, "客户机未使用硬件光标"));
        }
        if let Some((cursor, showing)) = current_cursor()
            && last != Some((cursor, showing))
        {
            let update = if !showing {
                Some(GuestCursor::Hidden)
            } else if let Some(kind) = lookup(&system, cursor) {
                Some(GuestCursor::System(kind))
            } else {
                unsafe { cursor_image(cursor) }.map(GuestCursor::Image)
            };
            if let Some(update) = update {
                on_change(update)?;
                last = Some((cursor, showing));
            }
        }
        thread::sleep(POLL_INTERVAL);
    }
    Ok(())
}

fn watch_hidden_cursors(alive: impl Fn() -> bool, mut on_change: impl FnMut(GuestCursor) -> io::Result<()>) -> io::Result<()> {
    // 让 GetDpiForMonitor 报实际缩放，用于发现缩放变化。
    // SAFETY: 只影响本线程，推送线程专用。
    unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    let _hidden = HiddenCursors::acquire();
    let mut last: Option<(HCURSOR, bool, u64)> = None;
    while alive() {
        let generation = HiddenCursors::refresh(effective_dpi());
        if let Some((cursor, showing)) = current_cursor()
            && last != Some((cursor, showing, generation))
        {
            let kind = if showing { HiddenCursors::kind(cursor) } else { None };
            on_change(kind.map_or(GuestCursor::Hidden, GuestCursor::System))?;
            last = Some((cursor, showing, generation));
        }
        thread::sleep(POLL_INTERVAL);
    }
    Ok(())
}

/// 当前光标句柄与是否显示；锁屏、UAC 等安全桌面上取不到。
fn current_cursor() -> Option<(HCURSOR, bool)> {
    // SAFETY: 结构体先填 cbSize。
    let mut info: CURSORINFO = unsafe { zeroed() };
    info.cbSize = size_of::<CURSORINFO>() as u32;
    (unsafe { GetCursorInfo(&mut info) } != 0).then(|| (info.hCursor, info.flags & CURSOR_SHOWING != 0 && !info.hCursor.is_null()))
}

/// 推给宿主的系统光标：编号与种类名（协议里 `CursorShape.system` 的取值）。
const SYSTEM_CURSORS: [(SYSTEM_CURSOR_ID, &str); 15] = [
    (OCR_NORMAL, "arrow"),
    (OCR_IBEAM, "ibeam"),
    (OCR_WAIT, "wait"),
    (OCR_CROSS, "crosshair"),
    (OCR_UP, "uparrow"),
    (OCR_SIZENWSE, "sizenwse"),
    (OCR_SIZENESW, "sizenesw"),
    (OCR_SIZEWE, "sizewe"),
    (OCR_SIZENS, "sizens"),
    (OCR_SIZEALL, "sizeall"),
    (OCR_NO, "no"),
    (OCR_HAND, "hand"),
    (OCR_APPSTARTING, "appstarting"),
    (OCR_HELP, "help"),
    (32671, "pin"),
];

type CursorTable = Vec<(usize, &'static str)>;

fn system_cursor_handles() -> CursorTable {
    SYSTEM_CURSORS
        .iter()
        // SAFETY: 系统光标按编号取共享句柄，不用释放。
        .map(|&(id, kind)| (unsafe { LoadCursorW(ptr::null_mut(), id as usize as *const u16) } as usize, kind))
        .filter(|&(handle, _)| handle != 0)
        .collect()
}

fn lookup(table: &CursorTable, cursor: HCURSOR) -> Option<&'static str> {
    table.iter().find(|&&(handle, _)| handle == cursor as usize).map(|&(_, kind)| kind)
}

/// 推送连接共用的替换状态：有连接时系统光标是透明的，`table` 记着被替换的句柄。
struct HiddenCursors {
    users: usize,
    dpi: u32,
    /// 每次重新替换加一，推送循环据此重发当前光标。
    generation: u64,
    table: CursorTable,
}

static HIDDEN: Mutex<HiddenCursors> = Mutex::new(HiddenCursors { users: 0, dpi: 0, generation: 0, table: Vec::new() });

/// 推送连接持有期间系统光标保持透明，最后一个释放时恢复。
struct HiddenCursorsGuard;

impl HiddenCursors {
    fn lock() -> std::sync::MutexGuard<'static, HiddenCursors> {
        HIDDEN.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn acquire() -> HiddenCursorsGuard {
        Self::lock().users += 1;
        HiddenCursorsGuard
    }

    /// 缩放一变就重新替换，Windows 可能按新缩放重新载入系统光标；返回当前代数。
    fn refresh(dpi: u32) -> u64 {
        let mut state = Self::lock();
        if state.dpi != dpi {
            state.dpi = dpi;
            state.generation += 1;
            state.table = hide_system_cursors();
        }
        state.generation
    }

    fn kind(cursor: HCURSOR) -> Option<&'static str> {
        lookup(&Self::lock().table, cursor)
    }
}

impl Drop for HiddenCursorsGuard {
    fn drop(&mut self) {
        let mut state = HiddenCursors::lock();
        state.users -= 1;
        if state.users == 0 {
            state.dpi = 0;
            state.table.clear();
            restore_system_cursors();
        }
    }
}

/// 按光标方案重新载入系统光标。
pub fn restore_system_cursors() {
    // SAFETY: SPI_SETCURSORS 不用参数指针。
    unsafe { SystemParametersInfoW(SPI_SETCURSORS, 0, ptr::null_mut(), 0) };
}

fn effective_dpi() -> u32 {
    let (mut x, mut y) = (0u32, 0u32);
    // SAFETY: 输出指针有效；主显示器总存在。
    let ok = unsafe { GetDpiForMonitor(MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY), MDT_EFFECTIVE_DPI, &mut x, &mut y) } == 0;
    if ok && x > 0 { x } else { 96 }
}

/// 把系统光标逐个换成透明光标，返回被替换的句柄。替换只改内容，句柄通常不变，替换前后的都记下。
fn hide_system_cursors() -> CursorTable {
    restore_system_cursors();
    let mut table = system_cursor_handles();
    for (id, kind) in SYSTEM_CURSORS {
        let blank = blank_cursor();
        // SAFETY: SetSystemCursor 接管并销毁传入的光标。
        if blank.is_null() || unsafe { SetSystemCursor(blank, id) } == 0 {
            continue;
        }
        let replaced = unsafe { LoadCursorW(ptr::null_mut(), id as usize as *const u16) } as usize;
        if replaced != 0 && lookup(&table, replaced as HCURSOR).is_none() {
            table.push((replaced, kind));
        }
    }
    table
}

/// 全透明的光标：AND 掩码全 1、XOR 掩码全 0。
fn blank_cursor() -> HCURSOR {
    const SIZE: usize = 32;
    let and = [0xffu8; SIZE * SIZE / 8];
    let xor = [0u8; SIZE * SIZE / 8];
    // SAFETY: 两个掩码都是 SIZE×SIZE 的单色位图。
    unsafe { CreateCursor(ptr::null_mut(), 0, 0, SIZE as i32, SIZE as i32, and.as_ptr().cast(), xor.as_ptr().cast()) }
}

/// 读出光标位图。彩色光标带 alpha 时直接用，没有 alpha 时按 AND 掩码定透明；单色光标的掩码上半是 AND、下半是 XOR，
/// 取反像素（AND 与 XOR 都为 1）画成黑色。
unsafe fn cursor_image(cursor: HCURSOR) -> Option<CursorImage> {
    let mut icon: ICONINFO = unsafe { zeroed() };
    if unsafe { GetIconInfo(cursor, &mut icon) } == 0 {
        return None;
    }
    let result = unsafe { read_icon(&icon) };
    unsafe {
        if !icon.hbmMask.is_null() { DeleteObject(icon.hbmMask); }
        if !icon.hbmColor.is_null() { DeleteObject(icon.hbmColor); }
    }
    result
}

unsafe fn read_icon(icon: &ICONINFO) -> Option<CursorImage> {
    let mut mask_info: BITMAP = unsafe { zeroed() };
    if unsafe { GetObjectW(icon.hbmMask, size_of::<BITMAP>() as i32, (&mut mask_info as *mut BITMAP).cast()) } == 0 {
        return None;
    }
    let width = mask_info.bmWidth.max(0) as usize;
    let monochrome = icon.hbmColor.is_null();
    let height = if monochrome { mask_info.bmHeight.max(0) as usize / 2 } else { mask_info.bmHeight.max(0) as usize };
    if width == 0 || height == 0 || width > 256 || height > 256 {
        return None;
    }
    let mask = unsafe { read_bitmap(icon.hbmMask, width, if monochrome { height * 2 } else { height })? };
    let mut bgra = vec![0u8; width * height * 4];
    if monochrome {
        for i in 0..width * height {
            let and = mask[i * 4] != 0;
            let xor = mask[(width * height + i) * 4] != 0;
            let px = match (and, xor) {
                (true, false) => [0, 0, 0, 0],
                (false, true) => [255, 255, 255, 255],
                _ => [0, 0, 0, 255],
            };
            bgra[i * 4..i * 4 + 4].copy_from_slice(&px);
        }
    } else {
        let color = unsafe { read_bitmap(icon.hbmColor, width, height)? };
        let has_alpha = color.as_chunks::<4>().0.iter().any(|p| p[3] != 0);
        for i in 0..width * height {
            let mut px = [color[i * 4], color[i * 4 + 1], color[i * 4 + 2], color[i * 4 + 3]];
            if !has_alpha {
                px[3] = if mask[i * 4] == 0 { 255 } else { 0 };
            }
            bgra[i * 4..i * 4 + 4].copy_from_slice(&px);
        }
    }
    Some(CursorImage { width: width as u32, height: height as u32, hot_x: icon.xHotspot, hot_y: icon.yHotspot, bgra })
}

/// 以 32 位、自上而下读出位图；单色位图转成黑白像素。
unsafe fn read_bitmap(bitmap: HBITMAP, width: usize, height: usize) -> Option<Vec<u8>> {
    let mut info: BITMAPINFO = unsafe { zeroed() };
    info.bmiHeader = BITMAPINFOHEADER {
        biSize: size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: width as i32,
        biHeight: -(height as i32),
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB,
        ..unsafe { zeroed() }
    };
    let mut pixels = vec![0u8; width * height * 4];
    let dc = unsafe { GetDC(ptr::null_mut()) };
    let lines = unsafe { GetDIBits(dc, bitmap, 0, height as u32, pixels.as_mut_ptr().cast(), &mut info, DIB_RGB_COLORS) };
    unsafe { ReleaseDC(ptr::null_mut(), dc) };
    (lines == height as i32).then_some(pixels)
}
