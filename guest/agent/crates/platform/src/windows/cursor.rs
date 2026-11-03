//! virtio-gpu 显卡驱动（viogpudo、viogpu3d）的硬件光标开关（驱动键下的 `HWCursor`，驱动启动时读取，INF 默认关）。
//!
//! 打开后 Windows 不再把光标画进画面，而是交给显卡：QEMU 的 virtio-gpu 把光标形状转给宿主，宿主用它作
//! 系统光标，跟手且无延迟；VZ 的 virtio-gpu 不显示硬件光标，打开后客户机里就看不到光标。
//! 同一台 Windows 在两种引擎下是不同的设备实例，各有自己的驱动键，所以只改当前在场的实例。
//!
//! viogpudo 换光标时先在控制队列上传图像、随即在光标队列上更新光标，不等上传完成；QEMU 先处理光标队列，
//! 拷到的总是上一个形状。所以光标形状由代理从客户机直接取（`watch_cursor`），不用 QEMU 转来的。

use std::io;
use std::mem::{size_of, zeroed};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use windows_sys::Win32::System::Registry::{KEY_QUERY_VALUE, KEY_SET_VALUE, REG_DWORD, RegCloseKey, RegQueryValueExW, RegSetValueExW};

use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAP, BITMAPINFO, BITMAPINFOHEADER, DIB_RGB_COLORS, DeleteObject, GetDC, GetDIBits, GetObjectW, HBITMAP, ReleaseDC,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{CURSOR_SHOWING, CURSORINFO, GetCursorInfo, GetIconInfo, HCURSOR, ICONINFO};

use super::gpu::{for_each_present_virtio_gpu, on_vz, open_driver_key};
use super::wide;
use crate::CursorImage;

/// 本次开机驱动是否已在使用硬件光标（驱动只在启动时读开关）。
static HARDWARE_CURSOR_ACTIVE: AtomicBool = AtomicBool::new(false);
/// 轮询当前光标的间隔，即形状变化最多晚这么久到达宿主；位置由宿主自己画，不受影响。
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// 按所在引擎设好在场 virtio-gpu 的硬件光标开关，返回是否改动（改动在下次开机生效）。
pub fn configure_hardware_cursor() -> bool {
    let enable = !on_vz();
    let mut changed = false;
    for_each_present_virtio_gpu(|set, info| {
        let Some(key) = open_driver_key(set, info, KEY_QUERY_VALUE | KEY_SET_VALUE) else { return };
        let name = wide("HWCursor");
        let mut current: u32 = 0;
        let mut size = size_of::<u32>() as u32;
        // SAFETY: 缓冲区与长度一致；键在本闭包内关闭。
        unsafe {
            let read = RegQueryValueExW(key, name.as_ptr(), ptr::null(), ptr::null_mut(), (&mut current as *mut u32).cast(), &mut size);
            let wanted = u32::from(enable);
            if enable && read == 0 && current == 1 {
                HARDWARE_CURSOR_ACTIVE.store(true, Ordering::Relaxed);
            }
            if read != 0 || current != wanted {
                changed |= RegSetValueExW(key, name.as_ptr(), 0, REG_DWORD, (&wanted as *const u32).cast(), size_of::<u32>() as u32) == 0;
            }
            RegCloseKey(key);
        }
    });
    changed
}

/// 光标变化时回调（`None` 表示隐藏），回调出错即返回。只有本次开机已在用硬件光标时才提供：
/// 否则客户机自己把光标画进画面，宿主再显示一个就成了两个。
pub fn watch_cursor(mut on_change: impl FnMut(Option<CursorImage>) -> io::Result<()>) -> io::Result<()> {
    if !HARDWARE_CURSOR_ACTIVE.load(Ordering::Relaxed) {
        return Err(io::Error::new(io::ErrorKind::Unsupported, "客户机未使用硬件光标"));
    }
    let mut last: Option<(HCURSOR, bool)> = None;
    loop {
        // SAFETY: 结构体先填 cbSize。
        let mut info: CURSORINFO = unsafe { zeroed() };
        info.cbSize = size_of::<CURSORINFO>() as u32;
        // 锁屏、UAC 等安全桌面上取不到，保持原样。
        if unsafe { GetCursorInfo(&mut info) } != 0 {
            let showing = info.flags & CURSOR_SHOWING != 0 && !info.hCursor.is_null();
            let current = (info.hCursor, showing);
            if last != Some(current) {
                let image = if showing { unsafe { cursor_image(info.hCursor) } } else { None };
                if !showing || image.is_some() {
                    on_change(image)?;
                    last = Some(current);
                }
            }
        }
        thread::sleep(POLL_INTERVAL);
    }
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
