//! 安全桌面（UAC 提示、锁屏与登录界面所在的 Winlogon 桌面）上的 UI 自动化。
//!
//! 只有 SYSTEM 身份、处在控制台会话里的线程能切到安全桌面上读树、注入与截屏，而代理以登录用户身份运行。
//! 开机时以 SYSTEM 运行的计划任务（会话 0）启动守护进程 `run_desktop_supervisor`，它把 SYSTEM 令牌改到控制台会话，
//! 在那里拉起桌面助手，会话变了或助手退出就重新拉起。助手在命名管道 `PIPE_NAME` 上一个连接受理一个 `ui-*` 请求，
//! 连接线程先切到当时的输入桌面再处理。代理遇到安全桌面上的请求时转给助手。
//!
//! 管道只许 SYSTEM 与已提权的 Administrators 连接，也不接受网络连接：否则未提权的进程借它能在 UAC 提示上点「是」。
//! 代理连接时核对管道归 SYSTEM 所有，并只许对方以识别级别冒充自己，抢先建同名管道的进程得不到代理的权限。

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, GENERIC_ALL, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE,
    INVALID_HANDLE_VALUE, LUID, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1, SE_KERNEL_OBJECT};
use windows_sys::Win32::Security::{
    AdjustTokenPrivileges, DuplicateTokenEx, IsWellKnownSid, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    SE_ASSIGNPRIMARYTOKEN_NAME, SE_INCREASE_QUOTA_NAME, SE_PRIVILEGE_ENABLED, SE_TCB_NAME, SECURITY_ATTRIBUTES, SecurityImpersonation,
    SetTokenInformation, TOKEN_ADJUST_DEFAULT, TOKEN_ADJUST_PRIVILEGES, TOKEN_ADJUST_SESSIONID, TOKEN_ALL_ACCESS, TOKEN_ASSIGN_PRIMARY,
    TOKEN_DUPLICATE, TOKEN_PRIVILEGES, TOKEN_QUERY, TokenPrimary, TokenSessionId, WinLocalSystemSid,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FlushFileBuffers, OPEN_EXISTING, PIPE_ACCESS_DUPLEX, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE,
    PIPE_UNLIMITED_INSTANCES, PIPE_WAIT, WaitNamedPipeW,
};
use windows_sys::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;
use windows_sys::Win32::System::StationsAndDesktops::{
    CloseDesktop, DESKTOP_READOBJECTS, GetThreadDesktop, GetUserObjectInformationW, HDESK, OpenInputDesktop, SetThreadDesktop, UOI_NAME,
};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, GetCurrentProcess, GetCurrentProcessId, GetCurrentThreadId, INFINITE, OpenProcess, OpenProcessToken, PROCESS_INFORMATION,
    PROCESS_SYNCHRONIZE, STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};

use super::{until_nul, wide};
use crate::cmdline::quote;
use macvm_agent_protocol::{InputEvent, Request};

const PIPE_NAME: &str = r"\\.\pipe\macvm-agent-desktop";
/// 助手进程的命令行参数，后跟守护进程的 pid。
pub const DESKTOP_HELPER_ARG: &str = "--desktop-helper";
/// 守护进程的命令行参数。
pub const DESKTOP_SUPERVISOR_ARG: &str = "--desktop-supervisor";
/// 助手给出的元素编号带这个前缀，代理据此把对这些元素的请求转给助手。
const HELPER_ELEMENT_PREFIX: &str = "s";
/// 管道归 SYSTEM 所有，只许 SYSTEM 与 Administrators（只在已提权的令牌里生效）访问，不继承父对象的权限。
const PIPE_SDDL: &str = "O:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)";
/// 管道每个方向的缓冲区大小。
const PIPE_BUFFER: u32 = 64 * 1024;
/// 所有管道实例都忙时最多等这么久。
const PIPE_BUSY_WAIT_MS: u32 = 5000;
/// 守护进程检查控制台会话与助手的间隔，也是助手退出后最晚多久重新拉起。
const SUPERVISE_INTERVAL: Duration = Duration::from_secs(1);
/// 换掉助手时等它退出的最长时间（毫秒）。
const HELPER_EXIT_WAIT_MS: u32 = 5000;
/// `WTSGetActiveConsoleSessionId` 在控制台会话切换期间返回这个值。
const NO_CONSOLE_SESSION: u32 = u32::MAX;

static IN_HELPER: AtomicBool = AtomicBool::new(false);

/// 本进程是桌面助手。
pub fn in_desktop_helper() -> bool {
    IN_HELPER.load(Ordering::Relaxed)
}

/// 本进程元素编号的前缀。
pub(super) fn element_prefix() -> &'static str {
    if in_desktop_helper() { HELPER_ELEMENT_PREFIX } else { "" }
}

fn helper_element(id: &str) -> bool {
    id.starts_with(HELPER_ELEMENT_PREFIX)
}

/// 代理要把这个 UI 请求转给桌面助手：请求针对助手给出的元素，或要在输入桌面上截屏、快照、注入，而输入桌面不是代理所在的桌面。
pub fn ui_request_for_desktop_helper(request: &Request) -> bool {
    if in_desktop_helper() {
        return false;
    }
    match request {
        Request::UiAction { element, .. } => helper_element(element),
        Request::UiInput { events } => {
            events.iter().any(|e| matches!(e, InputEvent::Click { element: Some(id), .. } if helper_element(id))) || !on_own_desktop()
        }
        Request::UiSnapshot { .. } | Request::UiScreenshot => !on_own_desktop(),
        _ => false,
    }
}

/// 输入桌面就是本线程所在的桌面。打不开输入桌面时（安全桌面只许 SYSTEM 打开）算不是。
fn on_own_desktop() -> bool {
    // SAFETY: 打开的桌面句柄在返回前关闭；线程自己的桌面句柄不用关。
    unsafe {
        let input = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS);
        if input.is_null() {
            return false;
        }
        let same = desktop_name(input).is_some_and(|name| desktop_name(GetThreadDesktop(GetCurrentThreadId())) == Some(name));
        CloseDesktop(input);
        same
    }
}

/// 桌面的名字，如 `Default`、`Winlogon`。
fn desktop_name(desktop: HDESK) -> Option<String> {
    let mut buf = [0u16; 256];
    let mut needed = 0u32;
    // SAFETY: 缓冲区大小如实传入。
    let ok = unsafe { GetUserObjectInformationW(desktop as HANDLE, UOI_NAME, buf.as_mut_ptr().cast(), size_of_val(&buf) as u32, &mut needed) };
    (ok != 0).then(|| String::from_utf16_lossy(until_nul(&buf)).to_ascii_lowercase())
}

/// 连上桌面助手。
pub fn connect_desktop_helper() -> io::Result<File> {
    let name = wide(PIPE_NAME);
    loop {
        // SAFETY: name 以 NUL 结尾；识别级别让管道另一端不能以代理的身份行事。
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                ptr::null_mut(),
            )
        };
        if handle != INVALID_HANDLE_VALUE {
            // SAFETY: handle 是刚打开的管道句柄，交给 File 管理。
            let pipe = unsafe { File::from_raw_handle(handle) };
            verify_system_server(&pipe)?;
            return Ok(pipe);
        }
        // SAFETY: 读本线程的错误码。
        match unsafe { GetLastError() } {
            // SAFETY: name 以 NUL 结尾。
            ERROR_PIPE_BUSY if unsafe { WaitNamedPipeW(name.as_ptr(), PIPE_BUSY_WAIT_MS) } != 0 => continue,
            ERROR_PIPE_BUSY => return Err(io::Error::new(io::ErrorKind::TimedOut, "桌面助手一直在忙")),
            ERROR_FILE_NOT_FOUND => {
                return Err(io::Error::other("当前在安全桌面（UAC 提示、锁屏或登录界面）上，而代理的桌面助手没有运行：在宿主上重新安装代理"));
            }
            // 类别一律为 Other：PermissionDenied 在协议里表示客户机缺授权（`CODE_PERMISSION`）。
            code => return Err(io::Error::other(format!("连接桌面助手失败：{}", io::Error::from_raw_os_error(code as i32)))),
        }
    }
}

/// 管道归 SYSTEM 所有：助手建管道时把所有者设为 SYSTEM，没有管理员特权的进程建的管道不会归 SYSTEM。
fn verify_system_server(pipe: &File) -> io::Result<()> {
    let mut owner: PSID = ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
    // SAFETY: owner 指向 descriptor 里的数据，用完后释放 descriptor。
    unsafe {
        let status = GetSecurityInfo(
            pipe.as_raw_handle(),
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            return Err(io::Error::other(format!("读取桌面助手管道的所有者失败：{}", io::Error::from_raw_os_error(status as i32))));
        }
        let system = IsWellKnownSid(owner, WinLocalSystemSid) != 0;
        LocalFree(descriptor);
        if system { Ok(()) } else { Err(io::Error::other("桌面助手的管道不归 SYSTEM 所有，不是助手建立的")) }
    }
}

/// 桌面助手的管道服务端。
pub struct DesktopHelperListener {
    security: PSECURITY_DESCRIPTOR,
    /// 下一个要等连接的管道实例。
    pending: Option<HANDLE>,
}

impl DesktopHelperListener {
    /// 建第一个管道实例；已有同名管道（另一个助手，或抢先建管道的进程）时失败。
    pub fn bind() -> io::Result<Self> {
        let sddl = wide(PIPE_SDDL);
        let mut security: PSECURITY_DESCRIPTOR = ptr::null_mut();
        // SAFETY: sddl 以 NUL 结尾；成功时 security 指向 LocalAlloc 的描述符，由 Drop 释放。
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut security, ptr::null_mut()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut listener = Self { security, pending: None };
        listener.pending = Some(listener.instance(true)?);
        Ok(listener)
    }

    fn instance(&self, first: bool) -> io::Result<HANDLE> {
        let name = wide(PIPE_NAME);
        let attributes = SECURITY_ATTRIBUTES { nLength: size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: self.security, bInheritHandle: 0 };
        let flags = PIPE_ACCESS_DUPLEX | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        // SAFETY: name 以 NUL 结尾，attributes 指向本对象持有的安全描述符。
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                flags,
                PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                PIPE_BUFFER,
                PIPE_BUFFER,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE { Err(io::Error::last_os_error()) } else { Ok(handle) }
    }

    /// 等下一个连接。
    pub fn accept(&mut self) -> io::Result<HelperConn> {
        let handle = match self.pending.take() {
            Some(h) => h,
            None => self.instance(false)?,
        };
        // SAFETY: handle 是本对象建的管道实例；连接失败时关掉它。
        unsafe {
            if ConnectNamedPipe(handle, ptr::null_mut()) == 0 && GetLastError() != ERROR_PIPE_CONNECTED {
                let error = io::Error::last_os_error();
                CloseHandle(handle);
                return Err(error);
            }
            Ok(HelperConn(File::from_raw_handle(handle)))
        }
    }
}

impl Drop for DesktopHelperListener {
    fn drop(&mut self) {
        // SAFETY: 关掉未用的实例，释放 bind 时分配的描述符。
        unsafe {
            if let Some(h) = self.pending.take() {
                CloseHandle(h);
            }
            LocalFree(self.security);
        }
    }
}

/// 桌面助手受理的一个连接。释放时等代理读完再断开，代理才不会丢掉响应的末尾。
pub struct HelperConn(File);

impl Read for HelperConn {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}

impl Write for HelperConn {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

impl Drop for HelperConn {
    fn drop(&mut self) {
        // SAFETY: 句柄由 File 持有，之后随它关闭。
        unsafe {
            FlushFileBuffers(self.0.as_raw_handle());
            DisconnectNamedPipe(self.0.as_raw_handle());
        }
    }
}

/// 本线程切到当前的输入桌面，释放时切回原来的桌面。
pub struct InputDesktop {
    desktop: HDESK,
    previous: HDESK,
}

/// 本线程切到当前的输入桌面；要在本线程建窗口、进 COM 套间之前调用。
pub fn enter_input_desktop() -> io::Result<InputDesktop> {
    // SAFETY: 打开输入桌面并让本线程用它；失败时关掉打开的句柄。
    unsafe {
        let previous = GetThreadDesktop(GetCurrentThreadId());
        let desktop = OpenInputDesktop(0, 0, GENERIC_ALL);
        if desktop.is_null() {
            return Err(io::Error::last_os_error());
        }
        if SetThreadDesktop(desktop) == 0 {
            let error = io::Error::last_os_error();
            CloseDesktop(desktop);
            return Err(error);
        }
        Ok(InputDesktop { desktop, previous })
    }
}

impl Drop for InputDesktop {
    fn drop(&mut self) {
        // SAFETY: 切回原来的桌面后才能关掉本线程用过的桌面句柄；切不回时句柄随线程留着。
        unsafe {
            if SetThreadDesktop(self.previous) != 0 {
                CloseDesktop(self.desktop);
            }
        }
    }
}

/// 进入桌面助手模式；守护进程退出时本进程随之退出，重装代理时停掉守护进程就能换掉可执行文件。
pub fn become_desktop_helper(supervisor: u32) -> io::Result<()> {
    // SAFETY: 只要等待权限；句柄移交给等待线程。
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, supervisor) };
    if process.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: process 是刚打开的进程句柄。
    let process = unsafe { OwnedHandle::from_raw_handle(process) };
    IN_HELPER.store(true, Ordering::Relaxed);
    std::thread::spawn(move || {
        // SAFETY: 等待有效的进程句柄。
        unsafe { WaitForSingleObject(process.as_raw_handle(), INFINITE) };
        std::process::exit(0);
    });
    Ok(())
}

/// 守护进程：在当前控制台会话里保持一个桌面助手，不返回。
pub fn run_desktop_supervisor() -> i32 {
    for privilege in [SE_TCB_NAME, SE_ASSIGNPRIMARYTOKEN_NAME, SE_INCREASE_QUOTA_NAME] {
        if let Err(e) = enable_privilege(privilege) {
            eprintln!("macvm-agent: 启用特权失败：{e}");
        }
    }
    let exe = match std::env::current_exe() {
        Ok(p) => p.to_string_lossy().into_owned(),
        Err(e) => {
            eprintln!("macvm-agent: 找不到自身路径：{e}");
            return 1;
        }
    };
    let mut helper: Option<Helper> = None;
    loop {
        // SAFETY: 无参数查询。
        let session = unsafe { WTSGetActiveConsoleSessionId() };
        if helper.as_ref().is_some_and(|h| h.session != session || h.exited()) {
            helper = None;
        }
        if helper.is_none() && session != NO_CONSOLE_SESSION {
            match spawn_helper(&exe, session) {
                Ok(h) => helper = Some(h),
                Err(e) => eprintln!("macvm-agent: 在会话 {session} 启动桌面助手失败：{e}"),
            }
        }
        std::thread::sleep(SUPERVISE_INTERVAL);
    }
}

struct Helper {
    process: OwnedHandle,
    session: u32,
}

impl Helper {
    fn exited(&self) -> bool {
        // SAFETY: 不等待，只查询进程是否已结束。
        unsafe { WaitForSingleObject(self.process.as_raw_handle(), 0) == 0 }
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        // SAFETY: 结束并等待本守护进程拉起的助手；它已退出时调用不起作用。
        unsafe {
            TerminateProcess(self.process.as_raw_handle(), 1);
            WaitForSingleObject(self.process.as_raw_handle(), HELPER_EXIT_WAIT_MS);
        }
    }
}

/// 以本进程的 SYSTEM 令牌在 `session` 的 Winlogon 桌面上启动助手。
fn spawn_helper(exe: &str, session: u32) -> io::Result<Helper> {
    let mut desktop = wide(r"winsta0\Winlogon");
    // SAFETY: 令牌句柄都交给 OwnedHandle 关闭；command 与 desktop 以 NUL 结尾，在 CreateProcessAsUserW 返回前有效。
    unsafe {
        let mut command = wide(&format!("{} {DESKTOP_HELPER_ARG} {}", quote(exe), GetCurrentProcessId()));
        let mut own = ptr::null_mut();
        let access = TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
        if OpenProcessToken(GetCurrentProcess(), access, &mut own) == 0 {
            return Err(io::Error::last_os_error());
        }
        let own = OwnedHandle::from_raw_handle(own);
        let mut token = ptr::null_mut();
        if DuplicateTokenEx(own.as_raw_handle(), TOKEN_ALL_ACCESS, ptr::null(), SecurityImpersonation, TokenPrimary, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = OwnedHandle::from_raw_handle(token);
        if SetTokenInformation(token.as_raw_handle(), TokenSessionId, (&session as *const u32).cast(), size_of::<u32>() as u32) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut startup: STARTUPINFOW = std::mem::zeroed();
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        startup.lpDesktop = desktop.as_mut_ptr();
        let mut info: PROCESS_INFORMATION = std::mem::zeroed();
        let created = CreateProcessAsUserW(
            token.as_raw_handle(),
            ptr::null(),
            command.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            0,
            0,
            ptr::null(),
            ptr::null(),
            &startup,
            &mut info,
        );
        if created == 0 {
            return Err(io::Error::last_os_error());
        }
        CloseHandle(info.hThread);
        Ok(Helper { process: OwnedHandle::from_raw_handle(info.hProcess), session })
    }
}

fn enable_privilege(name: windows_sys::core::PCWSTR) -> io::Result<()> {
    // SAFETY: 打开本进程令牌调整特权，句柄交给 OwnedHandle 关闭。
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = OwnedHandle::from_raw_handle(token);
        let mut luid = LUID { LowPart: 0, HighPart: 0 };
        if LookupPrivilegeValueW(ptr::null(), name, &mut luid) == 0 {
            return Err(io::Error::last_os_error());
        }
        let privileges = TOKEN_PRIVILEGES { PrivilegeCount: 1, Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }] };
        if AdjustTokenPrivileges(token.as_raw_handle(), 0, &privileges, 0, ptr::null_mut(), ptr::null_mut()) == 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
