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
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
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
        return Ok(());
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

/// Linux 与 macOS 客户机的缩放由桌面环境按显示器决定。
pub fn set_display_scale(_percent: u32) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "只有 Windows 客户机由代理设置缩放比例"))
}

pub fn mount_virtiofs(tag: &str, path: &str, read_only: bool) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        std::fs::create_dir_all(path)?;
        let options = if read_only { "ro" } else { "rw" };
        return run("/bin/mount", &["-t", "virtiofs", "-o", options, tag, path]);
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
