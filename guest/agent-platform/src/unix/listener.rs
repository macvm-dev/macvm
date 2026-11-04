use std::fs::File;
use std::io;
use std::os::fd::{FromRawFd, RawFd};

const AF_VSOCK: libc::c_int = 40;
const VMADDR_CID_ANY: u32 = u32::MAX;

#[cfg(target_os = "linux")]
#[repr(C)]
struct SockaddrVm {
    family: libc::sa_family_t,
    reserved1: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct SockaddrVm {
    len: u8,
    family: libc::sa_family_t,
    reserved1: u16,
    port: u32,
    cid: u32,
}

impl SockaddrVm {
    fn any(port: u32) -> Self {
        #[cfg(target_os = "linux")]
        return Self { family: AF_VSOCK as _, reserved1: 0, port, cid: VMADDR_CID_ANY, zero: [0; 4] };
        #[cfg(target_os = "macos")]
        return Self { len: std::mem::size_of::<Self>() as u8, family: AF_VSOCK as _, reserved1: 0, port, cid: VMADDR_CID_ANY };
    }
}

/// 宿主连入的连接（vsock，或 Linux 上的 TCP）。
pub type Conn = File;

/// 半关闭写方向；连接的其他克隆仍可读。
pub fn shutdown_write(conn: &Conn) {
    use std::os::fd::AsRawFd;
    // SAFETY: fd 由 conn 持有，shutdown 不改变其所有权。
    unsafe { libc::shutdown(conn.as_raw_fd(), libc::SHUT_WR) };
}

/// 宿主经 vsock 连入。Linux 上没有 virtio vsock 设备（QEMU 引擎）时改为监听 TCP：用户态网络把宿主的 Unix socket
/// 转发到这个端口，宿主以默认网关的地址出现；桥接网络下宿主直连客户机地址。TCP 连接按来源交出 `Origin`。
/// 有 vsock 设备时不开 TCP。
/// 没有 vsock 设备时 vsock 也可能绑定成功，所以按设备而不是按绑定结果判断。两种至少有一种监听成功即可。
pub struct Listener {
    vsock: Option<RawFd>,
    #[cfg(target_os = "linux")]
    tcp: Option<std::net::TcpListener>,
}

impl Listener {
    pub fn bind(port: u32) -> io::Result<Self> {
        let vsock = bind_vsock(port);
        #[cfg(target_os = "linux")]
        {
            if has_virtio_vsock() {
                return Ok(Self { vsock: Some(vsock?), tcp: None });
            }
            let tcp = u16::try_from(port).map_err(io::Error::other).and_then(|p| std::net::TcpListener::bind(("0.0.0.0", p)));
            match (vsock, tcp) {
                (Err(vsock), Err(tcp)) => Err(io::Error::other(format!("vsock：{vsock}；TCP：{tcp}"))),
                (vsock, tcp) => Ok(Self { vsock: vsock.ok(), tcp: tcp.ok() }),
            }
        }
        #[cfg(target_os = "macos")]
        Ok(Self { vsock: Some(vsock?) })
    }

    pub fn accept(&self) -> io::Result<(File, crate::Origin)> {
        #[cfg(target_os = "linux")]
        use std::os::fd::AsRawFd;
        let mut fds: Vec<libc::pollfd> = Vec::new();
        if let Some(fd) = self.vsock {
            fds.push(libc::pollfd { fd, events: libc::POLLIN, revents: 0 });
        }
        #[cfg(target_os = "linux")]
        if let Some(tcp) = &self.tcp {
            fds.push(libc::pollfd { fd: tcp.as_raw_fd(), events: libc::POLLIN, revents: 0 });
        }
        loop {
            fds.iter_mut().for_each(|p| p.revents = 0);
            // SAFETY: fds 是有效的 pollfd 数组，长度与之一致。
            if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) } < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            for ready in fds.iter().filter(|p| p.revents != 0) {
                if Some(ready.fd) == self.vsock {
                    if let Some(conn) = accept_raw(ready.fd)? {
                        return Ok((conn, crate::Origin::Vsock));
                    }
                    continue;
                }
                #[cfg(target_os = "linux")]
                if let Some(tcp) = &self.tcp {
                    let (stream, peer) = match tcp.accept() {
                        Ok(accepted) => accepted,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e),
                    };
                    stream.set_nodelay(true).ok();
                    let origin = if super::system::default_gateways().contains(&peer.ip()) { crate::Origin::Gateway } else { crate::Origin::Network };
                    return Ok((File::from(std::os::fd::OwnedFd::from(stream)), origin));
                }
            }
        }
    }
}

/// virtio 总线上是否有 vsock 设备（设备号 19）。virtio 设备在开机早期枚举，不依赖传输驱动是否已加载。
#[cfg(target_os = "linux")]
fn has_virtio_vsock() -> bool {
    const VIRTIO_ID_VSOCK: &str = "0x0013";
    let Ok(entries) = std::fs::read_dir("/sys/bus/virtio/devices") else { return false };
    entries
        .flatten()
        .any(|entry| std::fs::read_to_string(entry.path().join("device")).is_ok_and(|id| id.trim() == VIRTIO_ID_VSOCK))
}

fn bind_vsock(port: u32) -> io::Result<RawFd> {
    // SAFETY: 参数都是合法常量；返回值在下面检查。
    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | cloexec(), 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let addr = SockaddrVm::any(port);
    // SAFETY: addr 是按内核布局定义的 sockaddr_vm，长度与类型一致。
    let rc = unsafe {
        libc::bind(fd, &addr as *const SockaddrVm as *const libc::sockaddr, std::mem::size_of::<SockaddrVm>() as libc::socklen_t)
    };
    // SAFETY: fd 是刚创建的 socket。
    if rc != 0 || unsafe { libc::listen(fd, 64) } != 0 {
        let err = io::Error::last_os_error();
        // SAFETY: fd 由本函数独占，失败时关闭。
        unsafe { libc::close(fd) };
        return Err(err);
    }
    Ok(fd)
}

/// 被信号打断时返回 None，由调用方重新等待。
fn accept_raw(fd: RawFd) -> io::Result<Option<File>> {
    // SAFETY: 不需要对端地址，传空指针合法。
    let conn = unsafe { libc::accept(fd, std::ptr::null_mut(), std::ptr::null_mut()) };
    if conn >= 0 {
        set_cloexec(conn);
        // SAFETY: accept 返回的 fd 归调用方独占。
        return Ok(Some(unsafe { File::from_raw_fd(conn) }));
    }
    let err = io::Error::last_os_error();
    if err.kind() == io::ErrorKind::Interrupted { Ok(None) } else { Err(err) }
}

impl Drop for Listener {
    fn drop(&mut self) {
        if let Some(fd) = self.vsock {
            // SAFETY: fd 由本对象独占。
            unsafe { libc::close(fd) };
        }
    }
}

#[cfg(target_os = "linux")]
fn cloexec() -> libc::c_int {
    libc::SOCK_CLOEXEC
}

#[cfg(target_os = "macos")]
fn cloexec() -> libc::c_int {
    0
}

fn set_cloexec(fd: RawFd) {
    // SAFETY: 对有效 fd 设置标志位。
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

/// 与宿主共享的令牌，TCP 连接靠它认证。
/// macOS 客户机只经 vsock 连入，用不到。
pub fn agent_token() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/etc/macvm-agent/token").ok()?;
        let token = text.trim();
        if !token.is_empty() {
            return Some(token.to_owned());
        }
    }
    None
}

/// 读超时；None 取消。认证前限时，免得网上的连接一直占着线程。
pub fn set_read_timeout(conn: &Conn, timeout: Option<std::time::Duration>) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let t = timeout.unwrap_or_default();
    let tv = libc::timeval { tv_sec: t.as_secs() as _, tv_usec: t.subsec_micros() as _ };
    // SAFETY: fd 由 conn 持有；tv 在调用期间有效，长度与类型一致。
    let rc = unsafe {
        libc::setsockopt(conn.as_raw_fd(), libc::SOL_SOCKET, libc::SO_RCVTIMEO, (&tv as *const libc::timeval).cast(), std::mem::size_of::<libc::timeval>() as libc::socklen_t)
    };
    if rc == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}
