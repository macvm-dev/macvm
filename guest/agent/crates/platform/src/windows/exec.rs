use std::fs::File;
use std::io;
use std::os::windows::io::{FromRawHandle, OwnedHandle};
use std::process::{Child, Command, Stdio};
use std::ptr;
use std::sync::{Arc, Mutex};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::System::Console::{COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON, ResizePseudoConsole};
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::Threading::{
    CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
    INFINITE, InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    PROCESS_INFORMATION, STARTUPINFOEXW, UpdateProcThreadAttribute, WaitForSingleObject,
};

use super::{CREATE_NO_WINDOW, wide};
use crate::{ChildProcess, Exit, ExecOptions, Spawned, SpawnedIo};

/// 代理以登录用户身份运行，只能以该身份执行。
pub fn spawn(o: &ExecOptions) -> io::Result<Spawned> {
    if let Some(name) = o.user {
        let me = std::env::var("USERNAME").unwrap_or_default();
        if !name.eq_ignore_ascii_case(&me) {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("Windows 代理只能以 {me} 执行")));
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
    let stdin = File::from(OwnedHandle::from(child.stdin.take().unwrap()));
    let stdout = File::from(OwnedHandle::from(child.stdout.take().unwrap()));
    let stderr = File::from(OwnedHandle::from(child.stderr.take().unwrap()));
    Ok(Spawned { io: SpawnedIo::Pipes { stdin, stdout, stderr }, child: Box::new(PipeChild(child)) })
}

struct PipeChild(Child);

impl ChildProcess for PipeChild {
    fn wait(&mut self) -> io::Result<Exit> {
        let status = self.0.wait()?;
        Ok(Exit { code: status.code().unwrap_or(1), signal: None })
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

    let process = match create_process_with_console(o, hpc) {
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
        child: Box::new(PtyChild { process, console }),
    })
}

struct PtyChild {
    process: OwnedHandle,
    console: Arc<PseudoConsole>,
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
}

fn create_process_with_console(o: &ExecOptions, hpc: HPCON) -> io::Result<OwnedHandle> {
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
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            env.as_ptr() as *const _,
            cwd.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            &startup.StartupInfo,
            &mut info,
        );
        DeleteProcThreadAttributeList(attrs);
        if created == 0 { return Err(io::Error::last_os_error()) }
        CloseHandle(info.hThread);
        Ok(OwnedHandle::from_raw_handle(info.hProcess as _))
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

/// 按 MSVC 运行库解析命令行的规则给参数加引号。
fn quote(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '"']) {
        return arg.to_string();
    }
    let mut out = String::from("\"");
    let mut backslashes = 0;
    for c in arg.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(backslashes));
                backslashes = 0;
                out.push(c);
            }
        }
    }
    out.push_str(&"\\".repeat(backslashes * 2));
    out.push('"');
    out
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

#[cfg(test)]
mod tests {
    use super::quote;

    #[test]
    fn quoting() {
        assert_eq!(quote("plain"), "plain");
        assert_eq!(quote("a b"), "\"a b\"");
        assert_eq!(quote(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote(r"C:\dir\ "), r#""C:\dir\ ""#);
        assert_eq!(quote(r"C:\path with\"), r#""C:\path with\\""#);
    }
}
