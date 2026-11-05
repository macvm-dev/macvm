//! macOS：经 AppKit 的 NSPasteboard 读写通用剪贴板与拖放剪贴板里的文件。

use std::ffi::{CStr, CString, c_char, c_void};
use std::io;
use std::path::{Path, PathBuf};

type Id = *mut c_void;
type Sel = *const c_void;

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {
    static NSPasteboardNameDrag: Id;
    static NSPasteboardTypeFileURL: Id;
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    fn objc_msgSend();
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

/// 作用域内的自动释放池：消息返回的对象都是自动释放的，代理的工作线程没有现成的池。
struct Pool(*mut c_void);

impl Pool {
    fn new() -> Self {
        // SAFETY: 推入当前线程的自动释放池，析构时成对弹出。
        Self(unsafe { objc_autoreleasePoolPush() })
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        // SAFETY: 与 new 成对。
        unsafe { objc_autoreleasePoolPop(self.0) }
    }
}

fn class(name: &str) -> Id {
    let name = CString::new(name).expect("类名不含 NUL");
    // SAFETY: 按名字查类，AppKit 与 Foundation 已链接。
    unsafe { objc_getClass(name.as_ptr()) }
}

fn sel(name: &str) -> Sel {
    let name = CString::new(name).expect("选择子不含 NUL");
    // SAFETY: 注册或取回选择子。
    unsafe { sel_registerName(name.as_ptr()) }
}

/// `objc_msgSend` 按目标方法的签名转成函数指针调用；arm64 上参数与返回值的传法由签名决定，必须与方法一致。
macro_rules! msg {
    ($ret:ty; $obj:expr, $sel:expr $(, $arg:expr => $ty:ty)*) => {{
        // SAFETY: 由调用方保证接收者响应该选择子、参数与返回类型与方法签名一致。
        let f: unsafe extern "C" fn(Id, Sel $(, $ty)*) -> $ret = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
        unsafe { f($obj, sel($sel) $(, $arg)*) }
    }};
}

fn ns_string(s: &str) -> Id {
    let c = CString::new(s).unwrap_or_default();
    msg!(Id; class("NSString"), "stringWithUTF8String:", c.as_ptr() => *const c_char)
}

fn rust_string(s: Id) -> Option<String> {
    if s.is_null() {
        return None;
    }
    let p = msg!(*const c_char; s, "UTF8String");
    // SAFETY: UTF8String 返回 NUL 结尾的字符串，生存期与所在自动释放池相同，立即拷出。
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

/// `file://` URL 的本地路径；文件引用 URL（`/.file/id=…`）先解析成路径形式。
fn url_path(url: Id) -> Option<PathBuf> {
    if url.is_null() {
        return None;
    }
    let url = msg!(Id; url, "filePathURL");
    if url.is_null() {
        return None;
    }
    rust_string(msg!(Id; url, "path")).map(PathBuf::from)
}

/// `file://` URL 字符串的本地路径。
pub(crate) fn file_url_to_path(s: &str) -> Option<PathBuf> {
    let _pool = Pool::new();
    url_path(msg!(Id; class("NSURL"), "URLWithString:", ns_string(s) => Id))
}

fn files_on(pasteboard: Id) -> Vec<PathBuf> {
    let items = msg!(Id; pasteboard, "pasteboardItems");
    if items.is_null() {
        return Vec::new();
    }
    let count = msg!(usize; items, "count");
    // SAFETY: AppKit 导出的常量字符串。
    let file_url = unsafe { NSPasteboardTypeFileURL };
    (0..count)
        .filter_map(|i| {
            let item = msg!(Id; items, "objectAtIndex:", i => usize);
            let url = rust_string(msg!(Id; item, "stringForType:", file_url => Id))?;
            url_path(msg!(Id; class("NSURL"), "URLWithString:", ns_string(&url) => Id))
        })
        .collect()
}

pub fn clipboard_files() -> io::Result<Vec<PathBuf>> {
    let _pool = Pool::new();
    Ok(files_on(msg!(Id; class("NSPasteboard"), "generalPasteboard")))
}

/// 把剪贴板换成这些文件，在访达里粘贴即复制它们。
pub fn clipboard_set_files(paths: &[PathBuf]) -> io::Result<()> {
    let _pool = Pool::new();
    let urls = msg!(Id; class("NSMutableArray"), "array");
    for path in paths {
        let url = msg!(Id; class("NSURL"), "fileURLWithPath:", ns_string(&path.to_string_lossy()) => Id);
        msg!((); urls, "addObject:", url => Id);
    }
    let pasteboard = msg!(Id; class("NSPasteboard"), "generalPasteboard");
    msg!(isize; pasteboard, "clearContents");
    if msg!(bool; pasteboard, "writeObjects:", urls => Id) { Ok(()) } else { Err(io::Error::other("写入剪贴板失败")) }
}

/// 拖放剪贴板里的文件与它的变更计数。拖放结束后内容仍留着，是否在拖动由宿主比较前后两次的计数判断。
pub fn drag_files() -> io::Result<(Vec<PathBuf>, Option<i64>)> {
    let _pool = Pool::new();
    // SAFETY: AppKit 导出的常量字符串。
    let name = unsafe { NSPasteboardNameDrag };
    let pasteboard = msg!(Id; class("NSPasteboard"), "pasteboardWithName:", name => Id);
    let serial = msg!(isize; pasteboard, "changeCount") as i64;
    Ok((files_on(pasteboard), Some(serial)))
}

/// 当前用户的桌面目录。
pub(crate) fn desktop() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| io::Error::other("不知道用户目录"))?;
    let desktop = Path::new(&home).join("Desktop");
    Ok(if desktop.is_dir() { desktop } else { home.into() })
}
