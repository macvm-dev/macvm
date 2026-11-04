use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use crate::{ChildProcess, Exit, ExecOptions, Spawned, SpawnedIo};

/// 执行身份；agent 以 root 运行时切换到该用户。
#[derive(Debug, Clone)]
struct Identity {
    name: String,
    uid: u32,
    gid: u32,
    home: String,
    shell: String,
}

impl Identity {
    fn lookup(name: &str) -> io::Result<Self> {
        let cname = CString::new(name).map_err(io::Error::other)?;
        // SAFETY: getpwnam 返回指向静态区的指针，立即拷出所需字段。
        let pw = unsafe { libc::getpwnam(cname.as_ptr()) };
        if pw.is_null() {
            return Err(io::Error::new(io::ErrorKind::NotFound, format!("用户不存在：{name}")));
        }
        // SAFETY: pw 非空，字段由 libc 保证为合法 C 字符串。
        unsafe {
            Ok(Self {
                name: name.to_string(),
                uid: (*pw).pw_uid,
                gid: (*pw).pw_gid,
                home: cstr((*pw).pw_dir),
                shell: cstr((*pw).pw_shell),
            })
        }
    }

    fn current() -> io::Result<Self> {
        // SAFETY: getuid 无副作用；getpwuid 同 getpwnam。
        let pw = unsafe { libc::getpwuid(libc::getuid()) };
        if pw.is_null() {
            return Err(io::Error::other("无法确定当前用户"));
        }
        // SAFETY: 同上。
        let name = unsafe { cstr((*pw).pw_name) };
        Self::lookup(&name)
    }
}

/// SAFETY: p 必须为空或指向 NUL 结尾的字符串。
unsafe fn cstr(p: *const libc::c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: 由调用方保证。
    unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

struct Options<'a> {
    argv: &'a [String],
    cwd: Option<&'a str>,
    env: &'a [(String, String)],
    tty: Option<(u16, u16)>,
    identity: &'a Identity,
    /// 当前进程是 root 且需要降权。
    switch_user: bool,
}

/// 确定执行身份：root 可切到任意用户，否则只能以自身身份执行。
pub fn spawn(o: &ExecOptions) -> io::Result<Spawned> {
    let root = super::system::is_root();
    let identity = match o.user.or(o.default_user) {
        Some(name) if root => Identity::lookup(name)?,
        Some(name) => {
            let me = Identity::current()?;
            if me.name != name {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("代理不是 root，无法以 {name} 执行")));
            }
            me
        }
        None => Identity::current()?,
    };
    spawn_as(Options { argv: o.argv, cwd: o.cwd, env: o.env, tty: o.tty, identity: &identity, switch_user: root && identity.uid != 0 })
}

struct UnixChild {
    child: Child,
    /// 子进程尚未回收。挂断函数持锁发信号，`wait` 持锁改成 false 后才回收，进程号不会在发信号时已被复用。
    unreaped: Arc<Mutex<bool>>,
}

impl UnixChild {
    fn new(child: Child) -> Self {
        Self { child, unreaped: Arc::new(Mutex::new(true)) }
    }
}

impl ChildProcess for UnixChild {
    fn wait(&mut self) -> io::Result<Exit> {
        use std::os::unix::process::ExitStatusExt;
        wait_exited(self.child.id())?;
        *self.unreaped.lock().unwrap() = false;
        let status = self.child.wait()?;
        Ok(match (status.code(), status.signal()) {
            (Some(code), _) => Exit { code, signal: None },
            (None, Some(sig)) => Exit { code: 128 + sig, signal: Some(sig) },
            _ => Exit { code: 1, signal: None },
        })
    }

    /// 向子进程所在的进程组发 SIGHUP，与终端挂断时一样：忽略该信号的进程（如 nohup 启动的）继续运行。
    fn hangup(&self) -> io::Result<Box<dyn Fn() + Send + Sync>> {
        let pid = libc::pid_t::try_from(self.child.id()).map_err(io::Error::other)?;
        let unreaped = self.unreaped.clone();
        Ok(Box::new(move || {
            let unreaped = unreaped.lock().unwrap();
            if *unreaped {
                // SAFETY: 子进程未被回收，pid 仍指向它；pre_exec 里的 setsid 使它是自己进程组的组长。
                unsafe { libc::kill(-pid, libc::SIGHUP) };
            }
        }))
    }
}

/// 等子进程退出但不回收它。
fn wait_exited(pid: libc::id_t) -> io::Result<()> {
    loop {
        // SAFETY: siginfo_t 是普通 C 结构体，全零是合法值。
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: info 指向本地变量；WNOWAIT 让子进程留待 `Child::wait` 回收。
        if unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) } == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.kind() != io::ErrorKind::Interrupted {
            return Err(err);
        }
    }
}

/// 经用户的登录 shell 执行 argv，使 PATH 等环境与 SSH 登录一致。
fn spawn_as(o: Options) -> io::Result<Spawned> {
    let shell = if o.identity.shell.is_empty() { "/bin/sh".to_string() } else { o.identity.shell.clone() };
    let mut cmd = Command::new(&shell);
    cmd.arg("-l").arg("-c").arg(r#"exec "$@""#).arg("macvm-exec").args(o.argv);
    cmd.env_clear();
    for key in ["LANG", "LC_ALL"] {
        if let Ok(v) = std::env::var(key) {
            cmd.env(key, v);
        }
    }
    cmd.env("HOME", &o.identity.home)
        .env("USER", &o.identity.name)
        .env("LOGNAME", &o.identity.name)
        .env("SHELL", &shell)
        .env("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin");
    if o.tty.is_some() {
        cmd.env("TERM", "xterm-256color");
    }
    for (k, v) in o.env {
        cmd.env(k, v);
    }
    cmd.current_dir(o.cwd.unwrap_or(&o.identity.home));

    let (uid, gid, switch, name) = (o.identity.uid, o.identity.gid, o.switch_user, CString::new(o.identity.name.clone()).map_err(io::Error::other)?);
    #[cfg(target_os = "linux")]
    let groups = if switch { supplementary_groups(&name, gid)? } else { Vec::new() };
    let tty = o.tty.is_some();
    // SAFETY: pre_exec 闭包在 fork 后、exec 前运行，Linux 上只调用 async-signal-safe 的系统调用。
    // shortcut: macOS 上在子进程里调用 initgroups，它不是 async-signal-safe；macOS 代理以登录用户运行、不切换身份，改为以 root 运行时也在 fork 前取好附加组。
    unsafe {
        cmd.pre_exec(move || {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if tty && libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            if switch {
                #[cfg(target_os = "linux")]
                let joined = libc::setgroups(groups.len(), groups.as_ptr());
                #[cfg(target_os = "macos")]
                let joined = libc::initgroups(name.as_ptr(), gid as _);
                if joined != 0 || libc::setgid(gid) != 0 || libc::setuid(uid) != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }

    if let Some((cols, rows)) = o.tty {
        let (master, slave) = openpty(cols, rows)?;
        cmd.stdin(Stdio::from(slave.try_clone()?)).stdout(Stdio::from(slave.try_clone()?)).stderr(Stdio::from(slave));
        let child = cmd.spawn()?;
        let master = File::from(master);
        let control = master.try_clone()?;
        let resize = Box::new(move |cols: u16, rows: u16| resize(&control, cols, rows));
        Ok(Spawned { child: Box::new(UnixChild::new(child)), io: SpawnedIo::Pty { input: master.try_clone()?, output: master, resize } })
    } else {
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        let stdin = File::from(OwnedFd::from(child.stdin.take().unwrap()));
        let stdout = File::from(OwnedFd::from(child.stdout.take().unwrap()));
        let stderr = File::from(OwnedFd::from(child.stderr.take().unwrap()));
        Ok(Spawned { child: Box::new(UnixChild::new(child)), io: SpawnedIo::Pipes { stdin, stdout, stderr } })
    }
}

/// 用户 `name` 所在的全部组（含主组 `gid`）。在 fork 之前取：查组要读 /etc/group 和分配内存，不能放进子进程。
#[cfg(target_os = "linux")]
fn supplementary_groups(name: &std::ffi::CStr, gid: u32) -> io::Result<Vec<libc::gid_t>> {
    const MAX_GROUPS: usize = 65536;
    let mut groups: Vec<libc::gid_t> = vec![0; 64];
    loop {
        let mut count = libc::c_int::try_from(groups.len()).map_err(io::Error::other)?;
        // SAFETY: groups 至少有 count 个元素；getgrouplist 最多写这么多，并把实际组数写回 count。
        if unsafe { libc::getgrouplist(name.as_ptr(), gid, groups.as_mut_ptr(), &mut count) } >= 0 {
            groups.truncate(usize::try_from(count).unwrap_or(0));
            return Ok(groups);
        }
        if groups.len() >= MAX_GROUPS {
            return Err(io::Error::other(format!("{} 所在的组过多", name.to_string_lossy())));
        }
        let wanted = usize::try_from(count).unwrap_or(0).max(groups.len() * 2);
        groups.resize(wanted, 0);
    }
}

fn openpty(cols: u16, rows: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut master = -1;
    let mut slave = -1;
    let mut ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: 输出参数指向本地变量，name 与 termios 传空表示使用默认值。
    let rc = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), &raw mut ws) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // 从端也要 close-on-exec：其他线程同时 fork 出的子进程若继承了它，本会话的主端要等那个进程结束才读到结束。
    // 子进程的 0/1/2 是 dup2 出来的副本，不带这个标志。
    // SAFETY: openpty 成功后两个 fd 归调用方。
    unsafe {
        libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(slave, libc::F_SETFD, libc::FD_CLOEXEC);
        Ok((OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)))
    }
}

fn resize(pty: &File, cols: u16, rows: u16) {
    use std::os::fd::AsRawFd;
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: 对 PTY 主端设置窗口大小。
    unsafe { libc::ioctl(pty.as_raw_fd(), libc::TIOCSWINSZ as _, &ws) };
}
