use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

/// 执行身份；agent 以 root 运行时切换到该用户。
#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
}

impl Identity {
    pub fn lookup(name: &str) -> io::Result<Self> {
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

    pub fn current() -> io::Result<Self> {
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

pub struct Spawned {
    pub child: Child,
    /// tty 模式下是 PTY 主端（读写同一个），否则依次为 stdin、stdout、stderr 管道。
    pub io: SpawnedIo,
}

pub enum SpawnedIo {
    Pty(File),
    Pipes { stdin: File, stdout: File, stderr: File },
}

pub struct Options<'a> {
    pub argv: &'a [String],
    pub cwd: Option<&'a str>,
    pub env: &'a [(String, String)],
    pub tty: Option<(u16, u16)>,
    pub identity: &'a Identity,
    /// 当前进程是 root 且需要降权。
    pub switch_user: bool,
}

/// 经用户的登录 shell 执行 argv，使 PATH 等环境与 SSH 登录一致。
pub fn spawn(o: Options) -> io::Result<Spawned> {
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
    let tty = o.tty.is_some();
    // SAFETY: pre_exec 闭包在 fork 后、exec 前运行，只调用 async-signal-safe 的系统调用。
    unsafe {
        cmd.pre_exec(move || {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if tty && libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            if switch {
                if libc::initgroups(name.as_ptr(), gid as _) != 0 || libc::setgid(gid) != 0 || libc::setuid(uid) != 0 {
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
        Ok(Spawned { child, io: SpawnedIo::Pty(File::from(master)) })
    } else {
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        let stdin = File::from(OwnedFd::from(child.stdin.take().unwrap()));
        let stdout = File::from(OwnedFd::from(child.stdout.take().unwrap()));
        let stderr = File::from(OwnedFd::from(child.stderr.take().unwrap()));
        Ok(Spawned { child, io: SpawnedIo::Pipes { stdin, stdout, stderr } })
    }
}

fn openpty(cols: u16, rows: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut master = -1;
    let mut slave = -1;
    let mut ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: 输出参数指向本地变量，name 与 termios 传空表示使用默认值。
    let rc = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), &mut ws) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty 成功后两个 fd 归调用方。
    unsafe {
        libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC);
        Ok((OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)))
    }
}

pub fn resize(pty: &File, cols: u16, rows: u16) {
    use std::os::fd::AsRawFd;
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: 对 PTY 主端设置窗口大小。
    unsafe { libc::ioctl(pty.as_raw_fd(), libc::TIOCSWINSZ as _, &ws) };
}
