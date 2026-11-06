use std::fs::File;
use std::io;
use std::os::windows::io::{FromRawHandle, OwnedHandle};
use std::process::{Child, Command, Stdio};
use std::ptr;
use std::sync::{Arc, Mutex};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::System::Console::{COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON, ResizePseudoConsole};
use windows_sys::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject};
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
    INFINITE, InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    PROCESS_INFORMATION, ResumeThread, STARTUPINFOEXW, TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject,
};

use super::{CREATE_NO_WINDOW, wide};
use crate::cmdline::quote;
use crate::{ChildProcess, Exit, ExecOptions, Spawned, SpawnedIo};

/// 代理以登录用户身份运行，只能以该身份执行。
pub fn spawn(o: &ExecOptions) -> io::Result<Spawned> {
    if let Some(name) = o.user {
        let me = std::env::var("USERNAME").unwrap_or_default();
        if !name.eq_ignore_ascii_case(&me) {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("On Windows, the agent can only run commands as {me}")));
        }
    }
    match o.tty {
        Some((cols, rows)) => spawn_pty(o, cols, rows),
        None => spawn_pipes(o),
    }
}

fn spawn_pipes(o: &ExecOptions) -> io::Result<Spawned> {
    use std::os::windows::process::CommandExt;
    let mut cmd = Command::new(&o.argv[0]);
    // 代理本身没有控制台，不加这个标志时每个控制台子进程都会弹出一个窗口。
    cmd.args(&o.argv[1..]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
    if let Some(cwd) = o.cwd { cmd.current_dir(cwd); }
    for (k, v) in o.env { cmd.env(k, v); }
    let mut child = cmd.spawn()?;
    // shortcut: std 的 Command 不能挂起创建，子进程在加入作业前的瞬间启动的进程挂断不到；要补时改用 CreateProcessW 挂起创建。
    let group = {
        use std::os::windows::io::AsRawHandle;
        Group::new(child.as_raw_handle() as HANDLE)
    };
    let stdin = File::from(OwnedHandle::from(child.stdin.take().unwrap()));
    let stdout = File::from(OwnedHandle::from(child.stdout.take().unwrap()));
    let stderr = File::from(OwnedHandle::from(child.stderr.take().unwrap()));
    Ok(Spawned { io: SpawnedIo::Pipes { stdin, stdout, stderr }, child: Box::new(PipeChild { child, group }) })
}

struct PipeChild {
    child: Child,
    group: Group,
}

impl ChildProcess for PipeChild {
    fn wait(&mut self) -> io::Result<Exit> {
        let status = self.child.wait()?;
        Ok(Exit { code: status.code().unwrap_or(1), signal: None })
    }

    fn hangup(&self) -> io::Result<Box<dyn Fn() + Send + Sync>> {
        use std::os::windows::io::AsHandle;
        self.group.terminator(self.child.as_handle().try_clone_to_owned()?)
    }
}

/// 子进程和它启动的进程所在的作业；建不成作业时为空，挂断只结束子进程本身。
/// 作业不设随句柄关闭而结束：exec 结束后留在后台的进程照常运行。
struct Group {
    job: Option<Arc<OwnedHandle>>,
    /// 子进程对象已释放。挂断函数持锁检查，释放后不再结束作业里留在后台的进程。
    released: Arc<Mutex<bool>>,
}

impl Group {
    fn new(process: HANDLE) -> Self {
        // SAFETY: 无名作业、默认安全属性；成功后句柄归 OwnedHandle。进程句柄在调用期间有效。
        let job = unsafe {
            let job = CreateJobObjectW(ptr::null(), ptr::null());
            if job.is_null() {
                None
            } else {
                let job = OwnedHandle::from_raw_handle(job as _);
                (AssignProcessToJobObject(raw(&job), process) != 0).then(|| Arc::new(job))
            }
        };
        Self { job, released: Arc::new(Mutex::new(false)) }
    }

    /// 挂断函数：结束作业里的所有进程，没有作业时结束 `process`。进程句柄在闭包里一直有效，进程退出后再调用不误伤别的进程。
    fn terminator(&self, process: OwnedHandle) -> io::Result<Box<dyn Fn() + Send + Sync>> {
        let job = self.job.clone();
        let released = self.released.clone();
        Ok(Box::new(move || {
            let released = released.lock().unwrap();
            if *released {
                return;
            }
            // SAFETY: 作业与进程句柄由闭包持有。
            unsafe {
                match &job {
                    Some(job) => TerminateJobObject(raw(job), 1),
                    None => TerminateProcess(raw(&process), 1),
                }
            };
        }))
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        *self.released.lock().unwrap() = true;
    }
}

/// 伪控制台句柄，在调整尺寸的闭包与等待进程的一方之间共享；进程退出后关闭。
struct PseudoConsole(Mutex<Option<HPCON>>);

// SAFETY: HPCON 只是一个不透明句柄，对它的调用都经互斥锁串行化。
unsafe impl Send for PseudoConsole {}
unsafe impl Sync for PseudoConsole {}

fn spawn_pty(o: &ExecOptions, cols: u16, rows: u16) -> io::Result<Spawned> {
    // 两条匿名管道：我们写入 → 伪控制台读取；伪控制台写入 → 我们读取。
    let (pty_in_read, pty_in_write) = pipe()?;
    let (pty_out_read, pty_out_write) = pipe()?;

    let mut hpc: HPCON = 0;
    let size = COORD { X: cols as i16, Y: rows as i16 };
    // SAFETY: 两个管道端在调用期间有效；成功后伪控制台持有自己的副本。
    let hr = unsafe { CreatePseudoConsole(size, raw(&pty_in_read), raw(&pty_out_write), 0, &mut hpc) };
    drop(pty_in_read);
    drop(pty_out_write);
    if hr < 0 {
        return Err(io::Error::from_raw_os_error(hr));
    }
    let console = Arc::new(PseudoConsole(Mutex::new(Some(hpc))));

    let (process, group) = match create_process_with_console(o, hpc) {
        Ok(p) => p,
        Err(e) => {
            // SAFETY: 进程没起来，伪控制台无人使用。
            unsafe { ClosePseudoConsole(hpc) };
            return Err(e);
        }
    };

    let control = console.clone();
    let resize = Box::new(move |cols: u16, rows: u16| {
        if let Some(h) = *control.0.lock().unwrap() {
            // SAFETY: 句柄在关闭前有效，锁保证不与关闭并发。
            unsafe { ResizePseudoConsole(h, COORD { X: cols as i16, Y: rows as i16 }) };
        }
    });
    Ok(Spawned {
        io: SpawnedIo::Pty { input: File::from(pty_in_write), output: File::from(pty_out_read), resize },
        child: Box::new(PtyChild { process, console, group }),
    })
}

struct PtyChild {
    process: OwnedHandle,
    console: Arc<PseudoConsole>,
    group: Group,
}

impl ChildProcess for PtyChild {
    /// 进程退出后关闭伪控制台，输出管道随之结束，读输出的线程才能退出。
    fn wait(&mut self) -> io::Result<Exit> {
        let handle = raw(&self.process);
        let mut code: u32 = 1;
        // SAFETY: 进程句柄由本对象持有。
        unsafe {
            if WaitForSingleObject(handle, INFINITE) != WAIT_OBJECT_0 { return Err(io::Error::last_os_error()) }
            GetExitCodeProcess(handle, &mut code);
        }
        if let Some(h) = self.console.0.lock().unwrap().take() {
            // SAFETY: 取出后不再有人使用该句柄。
            unsafe { ClosePseudoConsole(h) };
        }
        Ok(Exit { code: code as i32, signal: None })
    }

    fn hangup(&self) -> io::Result<Box<dyn Fn() + Send + Sync>> {
        self.group.terminator(self.process.try_clone()?)
    }
}

/// 挂起创建，加入作业后再放行，子进程启动的进程都在作业里。
fn create_process_with_console(o: &ExecOptions, hpc: HPCON) -> io::Result<(OwnedHandle, Group)> {
    let mut attr_size = 0usize;
    // SAFETY: 第一次调用只查询所需大小，按约定返回失败。
    unsafe { InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut attr_size) };
    let mut attr_buf = vec![0u8; attr_size];
    let attrs = attr_buf.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;

    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.lpAttributeList = attrs;

    let mut command_line = wide(&o.argv.iter().map(|a| quote(a)).collect::<Vec<_>>().join(" "));
    let cwd = o.cwd.map(wide);
    let env = environment_block(o.env);
    let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

    // SAFETY: 属性表缓冲区大小按查询结果分配，在 CreateProcessW 返回前一直有效；
    // 伪控制台属性的值按约定直接传句柄本身。
    unsafe {
        if InitializeProcThreadAttributeList(attrs, 1, 0, &mut attr_size) == 0 { return Err(io::Error::last_os_error()) }
        let ok = UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize, hpc as *const _, size_of::<HPCON>(), ptr::null_mut(), ptr::null());
        if ok == 0 {
            DeleteProcThreadAttributeList(attrs);
            return Err(io::Error::last_os_error());
        }
        let created = CreateProcessW(
            ptr::null(),
            command_line.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
            env.as_ptr() as *const _,
            cwd.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            &startup.StartupInfo,
            &mut info,
        );
        DeleteProcThreadAttributeList(attrs);
        if created == 0 { return Err(io::Error::last_os_error()) }
        let process = OwnedHandle::from_raw_handle(info.hProcess as _);
        let group = Group::new(info.hProcess);
        let resumed = ResumeThread(info.hThread) != u32::MAX;
        let err = io::Error::last_os_error();
        CloseHandle(info.hThread);
        if !resumed {
            // 放行失败时进程会一直挂起，等它退出的一方永远等不到。
            TerminateProcess(info.hProcess, 1);
            return Err(err);
        }
        Ok((process, group))
    }
}

/// 继承代理自身的环境再叠加请求里的变量，格式为 `K=V\0…\0\0`（UTF-16）。
fn environment_block(extra: &[(String, String)]) -> Vec<u16> {
    let mut vars: Vec<(String, String)> = std::env::vars().filter(|(k, _)| !extra.iter().any(|(e, _)| e.eq_ignore_ascii_case(k))).collect();
    vars.extend(extra.iter().cloned());
    let mut block = Vec::new();
    for (k, v) in vars {
        block.extend(format!("{k}={v}").encode_utf16());
        block.push(0);
    }
    block.push(0);
    block
}

fn pipe() -> io::Result<(OwnedHandle, OwnedHandle)> {
    let mut read: HANDLE = ptr::null_mut();
    let mut write: HANDLE = ptr::null_mut();
    let attrs = SECURITY_ATTRIBUTES { nLength: size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: ptr::null_mut(), bInheritHandle: 0 };
    // SAFETY: 输出参数指向本地变量；成功后两个句柄归调用方。
    unsafe {
        if CreatePipe(&mut read, &mut write, &attrs, 0) == 0 { return Err(io::Error::last_os_error()) }
        Ok((OwnedHandle::from_raw_handle(read as _), OwnedHandle::from_raw_handle(write as _)))
    }
}

fn raw(h: &OwnedHandle) -> HANDLE {
    use std::os::windows::io::AsRawHandle;
    h.as_raw_handle() as HANDLE
}
