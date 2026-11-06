//! Windows：投放点下资源管理器窗口的文件夹，以及正在拖动的文件。

use std::cell::RefCell;
use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HWND, POINTL};
use windows::Win32::System::Com::{
    CLSCTX_ALL, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, DVASPECT_CONTENT, FORMATETC, IDataObject,
    IServiceProvider, TYMED_HGLOBAL,
};
use windows::Win32::System::Ole::{DROPEFFECT, DROPEFFECT_NONE, IDropTarget, IDropTarget_Impl, OleInitialize, OleUninitialize, RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Shell::{
    FOLDERID_Desktop, IFolderView, IPersistFolder2, IShellBrowser, IShellWindows, IWebBrowserApp, KF_FLAG_DEFAULT, SHGetKnownFolderPath,
    SHGetPathFromIDListW, SID_STopLevelBrowser, ShellWindows,
};
use windows::core::{Interface, Ref, implement};
use windows_sys::Win32::Foundation::{LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::Memory::{GlobalLock, GlobalUnlock};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_MOVE, MOUSEINPUT, SendInput};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GA_ROOT, GetAncestor, GetClassNameW, GetSystemMetrics, IsWindowVisible, LWA_ALPHA,
    MSG, PM_REMOVE, PeekMessageW, RegisterClassW, SM_CXSCREEN, SM_CXVIRTUALSCREEN, SM_CYSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN, SW_SHOWNOACTIVATE, SetLayeredWindowAttributes, ShowWindow, TranslateMessage, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WindowFromPoint,
};

use super::clipboard::{CF_HDROP, hdrop_paths};
use super::{until_nul, wide};

pub const CLIPBOARD_FILES: bool = true;
pub const DRAG_FILES: bool = true;

fn com(e: windows::core::Error) -> io::Error {
    io::Error::other(e.message())
}

/// 本线程的 COM 单线程套间，析构时退出。资源管理器的 Shell 对象要在单线程套间里用。
struct Apartment;

impl Apartment {
    fn enter() -> Self {
        // SAFETY: 本线程进入单线程套间；已在别的套间里时调用失败，析构里的 CoUninitialize 与成功的调用成对，失败时多调一次无害。
        let _ = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        Apartment
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: 与 enter 成对。
        unsafe { CoUninitialize() }
    }
}

/// 当前用户的桌面目录。
fn desktop() -> io::Result<PathBuf> {
    // SAFETY: 成功时返回的字符串由 CoTaskMemAlloc 分配，拷出后释放。
    unsafe {
        let path = SHGetKnownFolderPath(&FOLDERID_Desktop, KF_FLAG_DEFAULT, None).map_err(com)?;
        let out = PathBuf::from(OsString::from_wide(path.as_wide()));
        CoTaskMemFree(Some(path.0 as *const _));
        Ok(out)
    }
}

/// 投放点（主屏宽、高的比例）下资源管理器窗口当前标签页的文件夹；点在桌面、别的程序上或认不出时为桌面。
pub fn drop_dir(point: Option<(f64, f64)>, _user: Option<&str>) -> io::Result<PathBuf> {
    let desktop = desktop()?;
    let Some((fx, fy)) = point else { return Ok(desktop) };
    super::dpi::per_monitor_thread();
    // SAFETY: 只查询主屏尺寸。
    let (width, height) = unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) };
    let at = POINT { x: (fx.clamp(0.0, 1.0) * f64::from(width - 1)) as i32, y: (fy.clamp(0.0, 1.0) * f64::from(height - 1)) as i32 };
    let _apartment = Apartment::enter();
    Ok(explorer_folder_at(at).filter(|p| p.is_dir()).unwrap_or(desktop))
}

fn explorer_folder_at(at: POINT) -> Option<PathBuf> {
    // SAFETY: 查询点下的顶层窗口与它的类名。
    let root = unsafe { GetAncestor(WindowFromPoint(at), GA_ROOT) };
    let mut class = [0u16; 64];
    // SAFETY: 缓冲区大小如实传入。
    let n = unsafe { GetClassNameW(root, class.as_mut_ptr(), class.len() as i32) };
    if String::from_utf16_lossy(&class[..n.max(0) as usize]) != "CabinetWClass" {
        return None;
    }
    // SAFETY: 经 IShellWindows 枚举资源管理器的每个标签页，找属于这个窗口、正显示着的那个。
    unsafe {
        let windows: IShellWindows = CoCreateInstance(&ShellWindows, None, CLSCTX_ALL).ok()?;
        for i in 0..windows.Count().ok()? {
            let Ok(browser) = windows.Item(&VARIANT::from(i)).and_then(|d| d.cast::<IWebBrowserApp>()) else { continue };
            if browser.HWND().ok().map(|h| h.0) != Some(root as isize) {
                continue;
            }
            let Ok(shell) = browser.cast::<IServiceProvider>().and_then(|s| s.QueryService::<IShellBrowser>(&SID_STopLevelBrowser)) else { continue };
            // 同一窗口的几个标签页都报这个窗口；只有当前标签页的窗口是可见的。
            if shell.GetWindow().is_ok_and(|tab| IsWindowVisible(tab.0 as _) == 0) {
                continue;
            }
            let folder: IPersistFolder2 = shell.QueryActiveShellView().ok()?.cast::<IFolderView>().ok()?.GetFolder().ok()?;
            let pidl = folder.GetCurFolder().ok()?;
            let mut path = [0u16; 260];
            let ok = SHGetPathFromIDListW(pidl, &mut path).as_bool();
            CoTaskMemFree(Some(pidl as *const _));
            return ok.then(|| PathBuf::from(OsString::from_wide(until_nul(&path))));
        }
    }
    None
}

/// 等系统把拖动交给投放窗口最多这么久。
const PROBE_TIMEOUT: Duration = Duration::from_millis(600);

/// 正在拖动的文件：在虚拟屏幕上临时铺一层几乎透明的投放窗口，挪一下光标让系统的拖放循环把数据交给它；
/// 投放窗口只读文件列表，总是拒绝投放。没有进行中的拖动时为空。
pub fn drag_files() -> io::Result<(Vec<PathBuf>, Option<i64>)> {
    // OLE 拖放要求投放窗口所在线程是单线程套间并转发消息，在专门的线程里做。
    let files = std::thread::spawn(probe).join().map_err(|_| io::Error::other("The drag-and-drop probe thread crashed"))??;
    Ok((files, None))
}

#[implement(IDropTarget)]
struct Probe {
    found: Rc<RefCell<Option<Vec<PathBuf>>>>,
}

impl IDropTarget_Impl for Probe_Impl {
    fn DragEnter(&self, data: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let files = data.as_ref().map(dropped_files).unwrap_or_default();
        *self.found.borrow_mut() = Some(files);
        // SAFETY: OLE 传入有效的输出指针。
        unsafe { *effect = DROPEFFECT_NONE };
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        // SAFETY: 同上。
        unsafe { *effect = DROPEFFECT_NONE };
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        Ok(())
    }

    fn Drop(&self, _data: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        // SAFETY: 同上。
        unsafe { *effect = DROPEFFECT_NONE };
        Ok(())
    }
}

/// 拖动数据里的 CF_HDROP 文件列表。
fn dropped_files(data: &IDataObject) -> Vec<PathBuf> {
    let format = FORMATETC { cfFormat: CF_HDROP as u16, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
    // SAFETY: 取 HGLOBAL 形式的 CF_HDROP，锁定期间读出文件名，用完释放存储介质。
    unsafe {
        let Ok(mut medium) = data.GetData(&format) else { return Vec::new() };
        let handle = medium.u.hGlobal.0;
        let locked = GlobalLock(handle);
        let files = if locked.is_null() { Vec::new() } else { hdrop_paths(locked) };
        GlobalUnlock(handle);
        ReleaseStgMedium(&mut medium);
        files
    }
}

unsafe extern "system" fn probe_window_proc(hwnd: *mut core::ffi::c_void, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // SAFETY: 原样交给默认窗口过程。
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

fn probe() -> io::Result<Vec<PathBuf>> {
    super::dpi::per_monitor_thread();
    // SAFETY: 本线程初始化 OLE，结束时成对退出；窗口、投放目标在退出前撤销与销毁。
    unsafe {
        OleInitialize(None).map_err(com)?;
        let result = probe_window();
        OleUninitialize();
        result
    }
}

/// SAFETY: 调用线程已 `OleInitialize`。
unsafe fn probe_window() -> io::Result<Vec<PathBuf>> {
    let class = wide("MacVMDragProbe");
    // SAFETY: 由调用方保证 OLE 已初始化；类重复注册时失败无害，窗口照样能用这个类名创建。
    unsafe {
        let wc = WNDCLASSW { lpfnWndProc: Some(probe_window_proc), lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
        RegisterClassW(&wc);
        let (x, y, w, h) =
            (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class.as_ptr(),
            std::ptr::null(),
            WS_POPUP,
            x,
            y,
            w,
            h,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null(),
        );
        if hwnd.is_null() {
            return Err(io::Error::last_os_error());
        }
        // 完全透明的分层窗口不参与命中测试，留一点不透明度。
        SetLayeredWindowAttributes(hwnd, 0, 1, LWA_ALPHA);
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let found = Rc::new(RefCell::new(None));
        let target: IDropTarget = Probe { found: found.clone() }.into();
        let registered = RegisterDragDrop(HWND(hwnd), &target);
        if registered.is_ok() {
            nudge_cursor();
            let deadline = Instant::now() + PROBE_TIMEOUT;
            while found.borrow().is_none() && Instant::now() < deadline {
                let mut msg: MSG = std::mem::zeroed();
                while PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let _ = RevokeDragDrop(HWND(hwnd));
        }
        DestroyWindow(hwnd);
        registered.map_err(com)?;
        Ok(found.borrow_mut().take().unwrap_or_default())
    }
}

/// 光标左右各挪一个像素：拖放循环在鼠标移动时才重新找投放目标。
fn nudge_cursor() {
    let step = |dx: i32| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy: 0, mouseData: 0, dwFlags: MOUSEEVENTF_MOVE, time: 0, dwExtraInfo: 0 } },
    };
    let inputs = [step(1), step(-1)];
    // SAFETY: inputs 是有效的 INPUT 数组，大小如实传入。
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}
