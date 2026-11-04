use std::io;
#[cfg(target_os = "macos")]
use std::process::Command;

use crate::run;

pub fn os_name() -> &'static str {
    if cfg!(target_os = "macos") { "macos" } else { "linux" }
}

pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: buf 足够大，gethostname 写入 NUL 结尾字符串。
    if unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) } != 0 {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// 非回环的 IPv4 地址。
pub fn ipv4_addresses() -> Vec<String> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs 分配链表，下面遍历后 freeifaddrs 释放。
    unsafe {
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut cur = head;
        while !cur.is_null() {
            let addr = (*cur).ifa_addr;
            let loopback = ((*cur).ifa_flags as libc::c_int & libc::IFF_LOOPBACK) != 0;
            if !addr.is_null() && (*addr).sa_family as libc::c_int == libc::AF_INET && !loopback {
                let sin = addr as *const libc::sockaddr_in;
                let ip = u32::from_be((*sin).sin_addr.s_addr);
                out.push(std::net::Ipv4Addr::from(ip).to_string());
            }
            cur = (*cur).ifa_next;
        }
        libc::freeifaddrs(head);
    }
    out
}

/// (总内存, 可用内存)，单位字节。
pub fn memory() -> (u64, u64) {
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
        let field = |name: &str| -> u64 {
            text.lines()
                .find(|l| l.starts_with(name))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<u64>().ok())
                .map_or(0, |kb| kb * 1024)
        };
        (field("MemTotal:"), field("MemAvailable:"))
    }
    #[cfg(target_os = "macos")]
    {
        let total = sysctl_u64("hw.memsize");
        let page = sysctl_u64("hw.pagesize").max(4096);
        let out = Command::new("/usr/bin/vm_stat").output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
        let pages = |name: &str| -> u64 {
            out.lines()
                .find(|l| l.starts_with(name))
                .and_then(|l| l.rsplit(':').next())
                .and_then(|v| v.trim().trim_end_matches('.').parse::<u64>().ok())
                .unwrap_or(0)
        };
        let available = (pages("Pages free") + pages("Pages inactive") + pages("Pages purgeable")) * page;
        (total, available.min(total))
    }
}

pub fn uptime_ms() -> u64 {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|t| t.split_whitespace().next()?.parse::<f64>().ok())
            .map_or(0, |s| (s * 1000.0) as u64)
    }
    #[cfg(target_os = "macos")]
    {
        let mut tv = libc::timeval { tv_sec: 0, tv_usec: 0 };
        let mut len = std::mem::size_of::<libc::timeval>();
        let name = c"kern.boottime";
        // SAFETY: 输出缓冲区为 timeval，长度匹配。
        let rc = unsafe { libc::sysctlbyname(name.as_ptr(), &mut tv as *mut _ as *mut libc::c_void, &mut len, std::ptr::null_mut(), 0) };
        if rc != 0 {
            return 0;
        }
        let boot = tv.tv_sec as u64 * 1000 + tv.tv_usec as u64 / 1000;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
        now.saturating_sub(boot)
    }
}

#[cfg(target_os = "macos")]
fn sysctl_u64(name: &str) -> u64 {
    let cname = std::ffi::CString::new(name).unwrap();
    let mut value: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    // SAFETY: 输出缓冲区为 u64，长度匹配。
    let rc = unsafe { libc::sysctlbyname(cname.as_ptr(), &mut value as *mut _ as *mut libc::c_void, &mut len, std::ptr::null_mut(), 0) };
    if rc == 0 { value } else { 0 }
}

pub(crate) fn is_root() -> bool {
    // SAFETY: 无副作用。
    unsafe { libc::geteuid() == 0 }
}

pub fn shutdown(reboot: bool) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    return run("/usr/bin/systemctl", &[if reboot { "reboot" } else { "poweroff" }]);
    #[cfg(target_os = "macos")]
    {
        if is_root() {
            return run("/sbin/shutdown", &[if reboot { "-r" } else { "-h" }, "now"]);
        }
        let verb = if reboot { "restart" } else { "shut down" };
        run("/usr/bin/osascript", &["-e", &format!("tell application \"System Events\" to {verb}")])
    }
}

pub fn set_time(unix_ms: i64) -> io::Result<()> {
    let ts = libc::timespec { tv_sec: (unix_ms / 1000) as _, tv_nsec: ((unix_ms % 1000) * 1_000_000) as _ };
    // SAFETY: ts 为有效 timespec；非 root 时内核返回 EPERM。
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn clipboard_get() -> io::Result<String> {
    #[cfg(target_os = "macos")]
    {
        let out = Command::new("/usr/bin/pbpaste").output()?;
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
    #[cfg(target_os = "linux")]
    Err(io::Error::new(io::ErrorKind::Unsupported, "Linux 客户机的剪贴板经 SPICE 代理同步"))
}

pub fn clipboard_set(text: &str) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::io::Write;
        let mut child = Command::new("/usr/bin/pbcopy").stdin(std::process::Stdio::piped()).spawn()?;
        child.stdin.take().unwrap().write_all(text.as_bytes())?;
        child.wait()?;
        Ok(())
    }
    #[cfg(target_os = "linux")]
    {
        let _ = text;
        Err(io::Error::new(io::ErrorKind::Unsupported, "Linux 客户机的剪贴板经 SPICE 代理同步"))
    }
}

/// 只有 Windows 客户机需要由代理提供光标形状。
pub fn watch_cursor(_alive: impl Fn() -> bool, _on_change: impl FnMut(crate::GuestCursor) -> io::Result<()>) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "只有 Windows 客户机提供光标形状"))
}

/// Linux 与 macOS 客户机的桌面自己跟随显示输出尺寸。
pub fn set_display(_width: u32, _height: u32) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "只有 Windows 客户机需要代理切换分辨率"))
}

/// Linux：把 GNOME 的整数缩放倍数（`percent` 四舍五入到 1–4 倍）写进每个图形会话用户的
/// `org.gnome.desktop.interface scaling-factor`，并用 `gdctl` 立即应用到当前画面。mutter 在没有保存过的显示器配置时
/// 按这个设置给新分辨率选缩放比例，所以之后窗口改分辨率也保持这个倍数。之后登录的会话由后台线程补上。
/// macOS 客户机的缩放由系统按显示器决定。
pub fn set_display_scale(percent: u32) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        gnome_scale::set(percent.saturating_add(50).div_euclid(100).clamp(1, 4));
        Ok(())
    }
    #[cfg(target_os = "macos")]
    {
        let _ = percent;
        Err(io::Error::new(io::ErrorKind::Unsupported, "macOS 客户机的缩放由系统决定"))
    }
}

#[cfg(target_os = "linux")]
mod gnome_scale {
    use std::collections::HashSet;
    use std::sync::{Mutex, Once};
    use std::time::Duration;

    /// 宿主最近要求的倍数，与已按它设置过的会话。
    static STATE: Mutex<(Option<u32>, Vec<String>)> = Mutex::new((None, Vec::new()));
    static WATCH: Once = Once::new();
    /// 新会话出现后多久能补上设置。
    const POLL: Duration = Duration::from_secs(2);

    pub fn set(factor: u32) {
        {
            let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
            if state.0 != Some(factor) {
                *state = (Some(factor), Vec::new());
            }
        }
        apply_pending();
        WATCH.call_once(|| {
            std::thread::spawn(|| loop {
                std::thread::sleep(POLL);
                apply_pending();
            });
        });
    }

    /// 给还没设置过的图形会话设置；会话结束后从记录里去掉。
    fn apply_pending() {
        let Some(factor) = STATE.lock().unwrap_or_else(|e| e.into_inner()).0 else { return };
        let sessions = graphical_sessions();
        let live: HashSet<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
        let pending: Vec<&Session> = {
            let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
            state.1.retain(|id| live.contains(id.as_str()));
            sessions.iter().filter(|s| !state.1.contains(&s.id)).collect()
        };
        for session in pending {
            if apply(session, factor) {
                let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
                if state.0 == Some(factor) {
                    state.1.push(session.id.clone());
                }
            }
        }
    }

    struct Session {
        id: String,
        user: String,
        uid: String,
    }

    /// systemd-logind 在 `/run/systemd/sessions/<ID>` 里记录每个会话，格式为 KEY=VALUE 行。
    fn graphical_sessions() -> Vec<Session> {
        let Ok(entries) = std::fs::read_dir("/run/systemd/sessions") else { return Vec::new() };
        entries
            .flatten()
            .filter_map(|entry| {
                let id = entry.file_name().into_string().ok()?;
                if id.contains('.') {
                    return None;
                }
                let text = std::fs::read_to_string(entry.path()).ok()?;
                let field = |key: &str| text.lines().find_map(|l| l.strip_prefix(key)?.strip_prefix('=')).map(str::to_owned);
                let graphical = matches!(field("TYPE").as_deref(), Some("wayland" | "x11"));
                let user_class = field("CLASS").as_deref() == Some("user");
                let closing = field("STATE").as_deref() == Some("closing");
                if !graphical || !user_class || closing {
                    return None;
                }
                Some(Session { id, user: field("USER")?, uid: field("UID")? })
            })
            .collect()
    }

    /// 以会话用户身份接上它的会话总线执行命令；成功时返回标准输出。
    fn as_user(session: &Session, args: &[&str]) -> Option<String> {
        let bus = format!("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{}/bus", session.uid);
        let runtime = format!("XDG_RUNTIME_DIR=/run/user/{}", session.uid);
        let output = std::process::Command::new("runuser")
            .args(["-u", &session.user, "--", "env", &bus, &runtime])
            .args(args)
            .output()
            .ok()?;
        output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
    }

    /// 设置写不进去（会话总线还没起来）时返回 false，下一轮再试。`gdctl` 只在单显示器时用，失败不算：
    /// 没有 `gdctl` 时设置在下次分辨率变化时生效。
    fn apply(session: &Session, factor: u32) -> bool {
        let value = factor.to_string();
        if as_user(session, &["gsettings", "set", "org.gnome.desktop.interface", "scaling-factor", &value]).is_none() {
            return false;
        }
        if let Some(show) = as_user(session, &["gdctl", "show"]) {
            let monitors: Vec<&str> = show
                .lines()
                .filter_map(|l| l.split("Monitor ").nth(1)?.split_whitespace().next())
                .collect();
            if let [monitor] = monitors[..] {
                let _ = as_user(session, &["gdctl", "set", "--logical-monitor", "--primary", "--monitor", monitor, "--scale", &value]);
            }
        }
        true
    }
}

pub fn mount_virtiofs(tag: &str, path: &str, read_only: bool) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        std::fs::create_dir_all(path)?;
        let options = if read_only { "ro" } else { "rw" };
        run("/bin/mount", &["-t", "virtiofs", "-o", options, tag, path])
    }
    #[cfg(target_os = "macos")]
    {
        let _ = (tag, path, read_only);
        Err(io::Error::new(io::ErrorKind::Unsupported, "macOS 客户机的共享目录由系统自动挂载"))
    }
}

/// 只有 Windows 客户机由宿主推送显卡驱动。
pub fn gpu_driver_package_is(_sha256: &str) -> bool {
    false
}

pub fn replace_gpu_driver(_zip: &[u8], _sha256: &str) -> io::Result<bool> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "只有 Windows 客户机由宿主推送显卡驱动"))
}
