//! 主屏截图：GDI 把屏幕拷进自顶向下的 32 位 DIB，再编码成 PNG。调用线程要先 `dpi::per_monitor_thread`。

use std::io;
use std::mem::size_of;
use std::ptr;
use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC,
    ReleaseDC, SRCCOPY, SelectObject,
};

pub fn png(width: u32, height: u32) -> io::Result<Vec<u8>> {
    let bgra = grab(width as i32, height as i32)?;
    let rgb: Vec<u8> = bgra.as_chunks::<4>().0.iter().flat_map(|p| [p[2], p[1], p[0]]).collect();
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width, height);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    let mut writer = encoder.write_header().map_err(io::Error::other)?;
    writer.write_image_data(&rgb).map_err(io::Error::other)?;
    writer.finish().map_err(io::Error::other)?;
    Ok(out)
}

/// 屏幕左上角 `width`×`height` 的 B G R X 像素，自上而下。
fn grab(width: i32, height: i32) -> io::Result<Vec<u8>> {
    if width <= 0 || height <= 0 {
        return Err(io::Error::other("读不到屏幕尺寸"));
    }
    // SAFETY: 依次创建并在返回前释放 DC、DIB；位图数据在 DeleteObject 之前拷出。
    unsafe {
        let screen = GetDC(ptr::null_mut());
        if screen.is_null() {
            return Err(io::Error::last_os_error());
        }
        let memory = CreateCompatibleDC(screen);
        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..std::mem::zeroed()
        };
        let mut bits: *mut std::ffi::c_void = ptr::null_mut();
        let bitmap = CreateDIBSection(memory, &info, DIB_RGB_COLORS, &mut bits, ptr::null_mut(), 0);
        let result = if bitmap.is_null() || bits.is_null() {
            Err(io::Error::last_os_error())
        } else {
            let previous = SelectObject(memory, bitmap);
            let copied = BitBlt(memory, 0, 0, width, height, screen, 0, 0, SRCCOPY | CAPTUREBLT);
            SelectObject(memory, previous);
            if copied == 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(std::slice::from_raw_parts(bits as *const u8, width as usize * height as usize * 4).to_vec())
            }
        };
        if !bitmap.is_null() {
            DeleteObject(bitmap);
        }
        DeleteDC(memory);
        ReleaseDC(ptr::null_mut(), screen);
        result
    }
}
