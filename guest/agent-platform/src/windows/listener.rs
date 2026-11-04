use std::io;
use std::net::{TcpListener, TcpStream};

/// 宿主经 TCP 连入的连接。
pub type Conn = TcpStream;

/// 半关闭写方向；连接的其他克隆仍可读。
pub fn shutdown_write(conn: &Conn) {
    let _ = conn.shutdown(std::net::Shutdown::Write);
}

/// 宿主已关闭连接或连接出错，不等待；连接里还有没读的数据时也能察觉。
pub fn peer_closed(conn: &Conn) -> bool {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{POLLERR, POLLHUP, POLLNVAL, POLLRDNORM, WSAPOLLFD, WSAPoll};
    let mut fd = WSAPOLLFD { fd: conn.as_raw_socket() as _, events: POLLRDNORM, revents: 0 };
    // SAFETY: fd 指向本地变量，只查询一个套接字。
    unsafe { WSAPoll(&mut fd, 1, 0) > 0 && fd.revents & (POLLHUP | POLLERR | POLLNVAL) != 0 }
}

/// Windows 客户机经 TCP 提供服务：QEMU 引擎没有 vsock，用户态网络把宿主的 Unix socket 转发到这个端口；
/// VZ 引擎下宿主直连客户机 NAT 地址。这两种情况下宿主以默认网关的地址出现；桥接网络下宿主直连客户机地址。
/// 连接按来源交出 `Origin`。
pub struct Listener {
    inner: TcpListener,
}

impl Listener {
    pub fn bind(port: u32) -> io::Result<Self> {
        let port = u16::try_from(port).map_err(io::Error::other)?;
        Ok(Self { inner: TcpListener::bind(("0.0.0.0", port))? })
    }

    pub fn accept(&self) -> io::Result<(Conn, crate::Origin)> {
        let (stream, peer) = self.inner.accept()?;
        stream.set_nodelay(true).ok();
        let origin = if super::system::default_gateways().contains(&peer.ip()) { crate::Origin::Gateway } else { crate::Origin::Network };
        Ok((stream, origin))
    }
}

/// 与宿主共享的令牌，连接靠它认证。文件只有 SYSTEM 与 Administrators 能读，代理以最高权限运行。
pub fn agent_token() -> Option<String> {
    let text = std::fs::read_to_string(r"C:\ProgramData\macvm\agent-token").ok()?;
    let token = text.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

/// 读超时；None 取消。认证前限时，免得网上的连接一直占着线程。
pub fn set_read_timeout(conn: &Conn, timeout: Option<std::time::Duration>) -> io::Result<()> {
    conn.set_read_timeout(timeout)
}
