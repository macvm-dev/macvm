use std::io;
use std::net::{IpAddr, Ipv4Addr};
use std::process::Command;

use windows_sys::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, NO_ERROR};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    GAA_FLAG_INCLUDE_GATEWAYS, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, GetAdaptersAddresses,
    IP_ADAPTER_ADDRESSES_LH,
};
use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
use windows_sys::Win32::Networking::WinSock::{AF_INET, SOCKADDR, SOCKADDR_IN};
use windows_sys::Win32::System::SystemInformation::{
    ComputerNameDnsHostname, GetComputerNameExW, GetTickCount64, GlobalMemoryStatusEx, MEMORYSTATUSEX,
};

pub fn os_name() -> &'static str {
    "windows"
}

pub fn hostname() -> String {
    let mut buf = [0u16; 256];
    let mut len = buf.len() as u32;
    // SAFETY: buf 与 len 描述同一块缓冲区。
    if unsafe { GetComputerNameExW(ComputerNameDnsHostname, buf.as_mut_ptr(), &mut len) } == 0 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..len as usize])
}

/// 遍历已启用网卡，交出 (单播 IPv4 地址, 默认网关 IPv4 地址)。
fn adapters() -> (Vec<Ipv4Addr>, Vec<Ipv4Addr>) {
    let flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let mut size: u32 = 16 * 1024;
    let mut buf: Vec<u64> = Vec::new();
    for _ in 0..3 {
        buf = vec![0u64; (size as usize).div_ceil(8)];
        // SAFETY: buf 按 8 字节对齐、长度为 size 字节。
        let rc = unsafe { GetAdaptersAddresses(AF_INET as u32, flags, std::ptr::null(), buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH, &mut size) };
        if rc == NO_ERROR { break }
        if rc != ERROR_BUFFER_OVERFLOW { return (vec![], vec![]) }
    }
    let (mut unicast, mut gateways) = (Vec::new(), Vec::new());
    // SAFETY: 成功返回后 buf 中是以 Next 串起的链表，生命周期不超过 buf。
    unsafe {
        let mut adapter = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
        while !adapter.is_null() {
            if (*adapter).OperStatus == IfOperStatusUp {
                let mut u = (*adapter).FirstUnicastAddress;
                while !u.is_null() {
                    if let Some(ip) = ipv4((*u).Address.lpSockaddr) { if !ip.is_loopback() { unicast.push(ip) } }
                    u = (*u).Next;
                }
                let mut g = (*adapter).FirstGatewayAddress;
                while !g.is_null() {
                    if let Some(ip) = ipv4((*g).Address.lpSockaddr) { gateways.push(ip) }
                    g = (*g).Next;
                }
            }
            adapter = (*adapter).Next;
        }
    }
    (unicast, gateways)
}

/// SAFETY: addr 为空或指向有效的 SOCKADDR。
unsafe fn ipv4(addr: *const SOCKADDR) -> Option<Ipv4Addr> {
    // SAFETY: 由调用方保证；族为 AF_INET 时按 SOCKADDR_IN 读取。
    unsafe {
        if addr.is_null() || (*addr).sa_family != AF_INET { return None }
        let sin = addr as *const SOCKADDR_IN;
        Some(Ipv4Addr::from(u32::from_be((*sin).sin_addr.S_un.S_addr)))
    }
}

pub fn ipv4_addresses() -> Vec<String> {
    adapters().0.iter().map(|ip| ip.to_string()).collect()
}

pub(crate) fn default_gateways() -> Vec<IpAddr> {
    adapters().1.into_iter().map(IpAddr::V4).collect()
}

pub fn memory() -> (u64, u64) {
    let mut status: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
    status.dwLength = size_of::<MEMORYSTATUSEX>() as u32;
    // SAFETY: dwLength 已按结构体大小设置。
    if unsafe { GlobalMemoryStatusEx(&mut status) } == 0 { return (0, 0) }
    (status.ullTotalPhys, status.ullAvailPhys)
}

pub fn uptime_ms() -> u64 {
    // SAFETY: 无参数。
    unsafe { GetTickCount64() }
}

fn run(program: &str, args: &[&str]) -> io::Result<()> {
    let status = Command::new(program).args(args).status()?;
    if status.success() { Ok(()) } else { Err(io::Error::other(format!("{program} 退出码 {status}"))) }
}

pub fn shutdown(reboot: bool) -> io::Result<()> {
    run("shutdown", &[if reboot { "/r" } else { "/s" }, "/t", "0"])
}

/// 恢复挂起后对时；修改系统时间需要管理员权限，代理以最高权限运行。
pub fn set_time(unix_ms: i64) -> io::Result<()> {
    let script = format!("Set-Date -Date ([DateTimeOffset]::FromUnixTimeMilliseconds({unix_ms}).LocalDateTime) | Out-Null");
    run("powershell", &["-NoProfile", "-NonInteractive", "-Command", &script])
}

pub use super::clipboard::{clipboard_get, clipboard_set};

pub fn mount_virtiofs(_tag: &str, _path: &str, _read_only: bool) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Windows 客户机暂不支持挂载 virtio-fs"))
}
