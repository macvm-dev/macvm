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
        (meminfo_bytes(&text, "MemTotal:"), meminfo_bytes(&text, "MemAvailable:"))
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

/// `/proc/meminfo` 里一项的字节数，没有这一项时为 0。
#[cfg(any(target_os = "linux", test))]
fn meminfo_bytes(text: &str, name: &str) -> u64 {
    text.lines()
        .find(|l| l.starts_with(name))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|v| v.parse::<u64>().ok())
        .map_or(0, |kb| kb * 1024)
}

/// 超出 `keep` 不到这么多时不回收，免得每次都为零头打扰内核。
#[cfg(target_os = "linux")]
const MIN_TRIM: u64 = 64 << 20;

/// 把文件页缓存（`Active(file)` 与 `Inactive(file)`）按 LRU 回收到约 `keep` 字节，内核支持时不换出匿名页。
pub fn trim_page_cache(keep: u64) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/proc/meminfo")?;
        let file = meminfo_bytes(&text, "Active(file):") + meminfo_bytes(&text, "Inactive(file):");
        let Some(excess) = file.checked_sub(keep).filter(|&n| n >= MIN_TRIM) else { return Ok(()) };
        let reclaim = |request: String| match std::fs::write("/sys/fs/cgroup/memory.reclaim", request) {
            // 回收不到要求的量时内核回 EAGAIN，已回收的部分照样生效。
            Err(e) if e.raw_os_error() == Some(libc::EAGAIN) => Ok(()),
            result => result,
        };
        match reclaim(format!("{excess} swappiness=0")) {
            // 不认识 swappiness 参数的内核回 EINVAL：按系统的 swappiness 回收。
            Err(e) if e.raw_os_error() == Some(libc::EINVAL) => reclaim(excess.to_string()),
            result => result,
        }
    }
    #[cfg(target_os = "macos")]
    {
        let _ = keep;
        Err(io::Error::new(io::ErrorKind::Unsupported, "macOS guests don't support trimming the page cache"))
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

/// 默认路由的网关。
#[cfg(target_os = "linux")]
pub(crate) fn default_gateways() -> Vec<std::net::IpAddr> {
    route_default_gateways(&std::fs::read_to_string("/proc/net/route").unwrap_or_default())
}

/// `/proc/net/route` 里目的地址为 0 的行的网关。内核把网络字节序的地址当作本机整数打印成十六进制，
/// ARM64 客户机是小端，按小端取回字节即为地址。
#[cfg(any(target_os = "linux", test))]
fn route_default_gateways(text: &str) -> Vec<std::net::IpAddr> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.get(1) != Some(&"00000000") {
                return None;
            }
            let gateway = u32::from_str_radix(fields.get(2)?, 16).ok()?;
            Some(std::net::IpAddr::V4(std::net::Ipv4Addr::from(gateway.to_le_bytes())))
        })
        .collect()
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

/// 有别的显卡时给固件帧缓冲接出的 simpledrm 显卡写一条 udev 规则，规则已在且相同时不动；规则做两件事：
/// - QEMU 的 ramfb 帧缓冲在 virtio-gpu 驱动加载后仍作为一块显卡留着，GNOME 会选它作主显卡、画到宿主看不到的地方，
///   所以让 GNOME 忽略它；
/// - gdm 要等到一块带 boot_vga 或 boot_display 的显卡、或挂在 platform 上的显卡才启动登录界面，virtio-gpu 都不是，
///   否则白等 10 秒；它按 `ID_PATH` 跳过 simpledrm，改掉 `ID_PATH` 后它就算 platform 显卡，gdm 立即放行。
///
/// simpledrm 是唯一的显卡时（只有 ramfb 的 QEMU）删掉规则，否则 GNOME 没有显卡可用。
/// 判断前先等 udev 处理完开机时的设备事件：代理可能早于 virtio-gpu 驱动加载启动，那时只看得到 simpledrm。
/// 改了规则就重新触发 drm 设备；GNOME 与 gdm 只在启动时按规则挑显卡，已在运行的下次启动才生效。
pub fn ignore_firmware_framebuffer() -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        const PATH: &str = "/etc/udev/rules.d/61-macvm-ignore-simpledrm.rules";
        const RULE: &str =
            "SUBSYSTEM==\"drm\", KERNEL==\"card*\", DRIVERS==\"simple-framebuffer\", TAG+=\"mutter-device-ignore\", ENV{ID_PATH}=\"macvm-firmware-framebuffer\"\n";
        let _ = run("udevadm", &["settle"]);
        let current = std::fs::read_to_string(PATH).ok();
        if has_other_gpu() {
            if current.as_deref() == Some(RULE) {
                return Ok(());
            }
            std::fs::create_dir_all("/etc/udev/rules.d")?;
            std::fs::write(PATH, RULE)?;
        } else {
            if current.is_none() {
                return Ok(());
            }
            std::fs::remove_file(PATH)?;
        }
        run("udevadm", &["control", "--reload"])?;
        run("udevadm", &["trigger", "--subsystem-match=drm", "--action=change", "--settle"])
    }
    #[cfg(target_os = "macos")]
    Ok(())
}

/// 除固件帧缓冲外是否还有 DRM 显卡。
#[cfg(target_os = "linux")]
fn has_other_gpu() -> bool {
    let Ok(entries) = std::fs::read_dir("/sys/class/drm") else { return false };
    entries.flatten().any(|entry| {
        let name = entry.file_name();
        let Some(card) = name.to_string_lossy().strip_prefix("card").and_then(|n| n.parse::<u32>().ok()) else { return false };
        entry.path().join("device/driver").exists() && !super::drm::is_firmware_framebuffer(card)
    })
}

pub fn set_time(unix_ms: i64) -> io::Result<()> {
    let ts = libc::timespec { tv_sec: (unix_ms / 1000) as _, tv_nsec: ((unix_ms % 1000) * 1_000_000) as _ };
    // SAFETY: ts 为有效 timespec；非 root 时内核返回 EPERM。
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// pbcopy 与 pbpaste 按 locale 决定文本编码，launchd 拉起的代理没有 `LANG`，不设就把非 ASCII 字符当成问号。
#[cfg(target_os = "macos")]
fn pasteboard_tool(path: &str) -> Command {
    let mut command = Command::new(path);
    command.env("LANG", "en_US.UTF-8");
    command
}

pub fn clipboard_get() -> io::Result<String> {
    #[cfg(target_os = "macos")]
    {
        let out = pasteboard_tool("/usr/bin/pbpaste").output()?;
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
    #[cfg(target_os = "linux")]
    Err(io::Error::new(io::ErrorKind::Unsupported, "Linux guests sync the clipboard through the SPICE agent"))
}

pub fn clipboard_set(text: &str) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::io::Write;
        let mut child = pasteboard_tool("/usr/bin/pbcopy").stdin(std::process::Stdio::piped()).spawn()?;
        child.stdin.take().unwrap().write_all(text.as_bytes())?;
        child.wait()?;
        Ok(())
    }
    #[cfg(target_os = "linux")]
    {
        let _ = text;
        Err(io::Error::new(io::ErrorKind::Unsupported, "Linux guests sync the clipboard through the SPICE agent"))
    }
}

/// 剪贴板里的文件经代理同步（`clipboard_files`、`clipboard_set_files`）。Linux 客户机的剪贴板经 SPICE 代理同步。
pub const CLIPBOARD_FILES: bool = cfg!(target_os = "macos");
/// 支持 `drag_files`。
pub const DRAG_FILES: bool = cfg!(target_os = "macos");

#[cfg(target_os = "linux")]
pub fn clipboard_files() -> io::Result<Vec<std::path::PathBuf>> {
    Ok(Vec::new())
}

#[cfg(target_os = "linux")]
pub fn clipboard_set_files(_paths: &[std::path::PathBuf]) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Linux guests sync the clipboard through the SPICE agent"))
}

#[cfg(target_os = "linux")]
pub fn drag_files() -> io::Result<(Vec<std::path::PathBuf>, Option<i64>)> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Linux guests don't support dragging files out"))
}

/// Linux：`user`（没有时为前台图形会话的用户）的 XDG 桌面目录，没有桌面目录时为其用户目录；不看投放点。
#[cfg(target_os = "linux")]
pub fn drop_dir(_point: Option<(f64, f64)>, user: Option<&str>) -> io::Result<std::path::PathBuf> {
    let user = match user {
        Some(user) => user.to_string(),
        None => super::session::graphical_sessions()
            .into_iter()
            .max_by_key(|s| s.active)
            .map(|s| s.user)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No user is logged in"))?,
    };
    let home = std::path::PathBuf::from(super::exec::home_dir(&user)?);
    let dirs = std::fs::read_to_string(home.join(".config/user-dirs.dirs")).unwrap_or_default();
    let desktop = xdg_desktop(&dirs, &home).unwrap_or_else(|| home.join("Desktop"));
    Ok(if desktop.is_dir() { desktop } else { home })
}

/// `user-dirs.dirs` 里的 `XDG_DESKTOP_DIR="$HOME/桌面"`。
#[cfg(any(target_os = "linux", test))]
fn xdg_desktop(dirs: &str, home: &std::path::Path) -> Option<std::path::PathBuf> {
    let value = dirs.lines().find_map(|l| l.trim().strip_prefix("XDG_DESKTOP_DIR="))?.trim_matches('"');
    Some(match value.strip_prefix("$HOME") {
        Some(rest) => home.join(rest.trim_start_matches('/')),
        None => value.into(),
    })
}

/// 只有 Windows 客户机需要由代理提供光标形状。
pub fn watch_cursor(_alive: impl Fn() -> bool, _on_change: impl FnMut(crate::GuestCursor) -> io::Result<()>) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Only Windows guests report the cursor shape"))
}

/// Linux 与 macOS 客户机的桌面自己跟随显示输出尺寸。
pub fn set_display(_width: u32, _height: u32) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Only Windows guests change the resolution through the agent"))
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
        Err(io::Error::new(io::ErrorKind::Unsupported, "macOS guests manage display scaling themselves"))
    }
}

#[cfg(target_os = "linux")]
mod gnome_scale {
    use crate::unix::session::{Session, graphical_sessions};
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

    /// 以会话用户身份接上它的会话总线执行命令；成功时返回标准输出。
    fn as_user(session: &Session, args: &[&str]) -> Option<String> {
        let output = std::process::Command::new("runuser")
            .args(["-u", &session.user, "--", "env"])
            .args(session.bus_env())
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
        Err(io::Error::new(io::ErrorKind::Unsupported, "macOS guests mount shared folders automatically"))
    }
}

/// 只有 Windows 客户机由宿主推送显卡驱动。
pub fn gpu_driver_package_is(_sha256: &str) -> bool {
    false
}

pub fn replace_gpu_driver(_zip: &[u8], _sha256: &str) -> io::Result<bool> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Only Windows guests get graphics drivers from the host"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn default_gateways_from_route_table() {
        let text = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n\
                    eth0\t00000000\t0140A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n\
                    eth0\t0040A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n\
                    eth1\t00000000\t0102000A\t0003\t0\t0\t200\t00000000\t0\t0\t0\n";
        assert_eq!(route_default_gateways(text), [IpAddr::V4(Ipv4Addr::new(192, 168, 64, 1)), IpAddr::V4(Ipv4Addr::new(10, 0, 2, 1))]);
        assert!(route_default_gateways("Iface\tDestination\tGateway\n").is_empty());
        assert!(route_default_gateways("").is_empty());
    }

    #[test]
    fn meminfo_fields() {
        let text = "MemTotal:        4014320 kB\nMemAvailable:    3000000 kB\nActive(file):     102400 kB\n";
        assert_eq!(meminfo_bytes(text, "MemTotal:"), 4014320 * 1024);
        assert_eq!(meminfo_bytes(text, "Active(file):"), 102400 * 1024);
        assert_eq!(meminfo_bytes(text, "Inactive(file):"), 0);
    }

    #[test]
    fn xdg_desktop_dir() {
        let home = std::path::Path::new("/home/ethan");
        assert_eq!(xdg_desktop("# x\nXDG_DESKTOP_DIR=\"$HOME/桌面\"\n", home), Some(home.join("桌面")));
        assert_eq!(xdg_desktop("XDG_DESKTOP_DIR=\"/data/desk\"", home), Some("/data/desk".into()));
        assert_eq!(xdg_desktop("XDG_DOWNLOAD_DIR=\"$HOME/dl\"", home), None);
    }
}
