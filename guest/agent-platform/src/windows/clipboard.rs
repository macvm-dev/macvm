use std::io;

use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows_sys::Win32::Foundation::GlobalFree;
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};

const CF_UNICODETEXT: u32 = 13;

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
