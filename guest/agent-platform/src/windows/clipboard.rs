use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;

use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, RegisterClipboardFormatW, SetClipboardData};
use windows_sys::Win32::Foundation::GlobalFree;
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GMEM_ZEROINIT, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows_sys::Win32::UI::Shell::DragQueryFileW;

const CF_UNICODETEXT: u32 = 13;
pub(super) const CF_HDROP: u32 = 15;
/// `DROPEFFECT_COPY`：粘贴时复制而不是移动。
const DROPEFFECT_COPY: u32 = 1;

/// 剪贴板属于登录会话，代理以登录用户身份在其会话里运行时才能访问。
struct Opened;

impl Opened {
    fn open() -> io::Result<Self> {
        // 别的程序可能短暂占用剪贴板：剪贴板历史服务（cbdhsvc）在每次复制后都要打开它读走内容，刚复制完时常要等上几百毫秒。
        for _ in 0..50 {
            // SAFETY: 不关联窗口打开剪贴板。
            if unsafe { OpenClipboard(std::ptr::null_mut()) } != 0 { return Ok(Opened) }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        Err(io::Error::last_os_error())
    }
}

impl Drop for Opened {
    fn drop(&mut self) {
        // SAFETY: 与 open 成对。
        unsafe { CloseClipboard() };
    }
}

pub fn clipboard_get() -> io::Result<String> {
    let _guard = Opened::open()?;
    // SAFETY: 剪贴板已打开；句柄在关闭前有效，锁定后按 UTF-16 NUL 结尾读取。
    unsafe {
        let handle = GetClipboardData(CF_UNICODETEXT);
        if handle.is_null() { return Ok(String::new()) }
        let ptr = GlobalLock(handle) as *const u16;
        if ptr.is_null() { return Err(io::Error::last_os_error()) }
        let mut len = 0;
        while *ptr.add(len) != 0 { len += 1 }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len));
        GlobalUnlock(handle);
        Ok(text)
    }
}

pub fn clipboard_set(text: &str) -> io::Result<()> {
    let wide = super::wide(text);
    let _guard = Opened::open()?;
    // SAFETY: 分配可移动全局内存并写入 UTF-16；SetClipboardData 成功后所有权归系统。
    unsafe {
        let mem = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2);
        if mem.is_null() { return Err(io::Error::last_os_error()) }
        let ptr = GlobalLock(mem) as *mut u16;
        std::ptr::copy_nonoverlapping(wide.as_ptr(), ptr, wide.len());
        GlobalUnlock(mem);
        EmptyClipboard();
        if SetClipboardData(CF_UNICODETEXT, mem).is_null() {
            GlobalFree(mem);
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// HDROP 里的文件路径。
///
/// SAFETY: `hdrop` 是有效的 HDROP（剪贴板或拖放数据里锁定的 DROPFILES）。
pub(super) unsafe fn hdrop_paths(hdrop: *mut core::ffi::c_void) -> Vec<PathBuf> {
    // SAFETY: 由调用方保证；先问长度再按长度取。
    unsafe {
        let count = DragQueryFileW(hdrop, u32::MAX, std::ptr::null_mut(), 0);
        (0..count)
            .map(|i| {
                let len = DragQueryFileW(hdrop, i, std::ptr::null_mut(), 0) as usize;
                let mut buf = vec![0u16; len + 1];
                DragQueryFileW(hdrop, i, buf.as_mut_ptr(), buf.len() as u32);
                PathBuf::from(OsString::from_wide(&buf[..len]))
            })
            .collect()
    }
}

pub fn clipboard_files() -> io::Result<Vec<PathBuf>> {
    let _guard = Opened::open()?;
    // SAFETY: 剪贴板已打开；CF_HDROP 的句柄就是 HDROP，在关闭前有效。
    unsafe {
        let handle = GetClipboardData(CF_HDROP);
        Ok(if handle.is_null() { Vec::new() } else { hdrop_paths(handle) })
    }
}

/// 把剪贴板换成这些文件（CF_HDROP，粘贴时复制），在资源管理器里粘贴即复制它们。
pub fn clipboard_set_files(paths: &[PathBuf]) -> io::Result<()> {
    // DROPFILES 头：pFiles（文件列表的偏移）、pt、fNC、fWide，随后是 UTF-16、各以 NUL 结尾、末尾再加一个 NUL 的路径列表。
    const HEADER: usize = 20;
    let mut list: Vec<u16> = paths.iter().flat_map(|p| p.as_os_str().encode_wide().chain(std::iter::once(0))).collect();
    list.push(0);
    let _guard = Opened::open()?;
    // SAFETY: 分配并填好两块可移动全局内存；SetClipboardData 成功后所有权归系统，失败时自己释放。
    unsafe {
        let drop = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, HEADER + list.len() * 2);
        if drop.is_null() { return Err(io::Error::last_os_error()) }
        let ptr = GlobalLock(drop) as *mut u8;
        (ptr as *mut u32).write_unaligned(HEADER as u32);
        (ptr.add(16) as *mut i32).write_unaligned(1);
        std::ptr::copy_nonoverlapping(list.as_ptr() as *const u8, ptr.add(HEADER), list.len() * 2);
        GlobalUnlock(drop);
        EmptyClipboard();
        if SetClipboardData(CF_HDROP, drop).is_null() {
            GlobalFree(drop);
            return Err(io::Error::last_os_error());
        }
        let effect_format = RegisterClipboardFormatW(super::wide("Preferred DropEffect").as_ptr());
        let effect = GlobalAlloc(GMEM_MOVEABLE, 4);
        if effect_format != 0 && !effect.is_null() {
            (GlobalLock(effect) as *mut u32).write_unaligned(DROPEFFECT_COPY);
            GlobalUnlock(effect);
            if SetClipboardData(effect_format, effect).is_null() {
                GlobalFree(effect);
            }
        }
    }
    Ok(())
}
