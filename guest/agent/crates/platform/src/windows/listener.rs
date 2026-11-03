use std::io;
use std::net::{TcpListener, TcpStream};

/// 宿主经 TCP 连入的连接。
pub type Conn = TcpStream;

/// 半关闭写方向；连接的其他克隆仍可读。
pub fn shutdown_write(conn: &Conn) {
    let _ = conn.shutdown(std::net::Shutdown::Write);
}

/// Windows 客户机经 TCP 提供服务：QEMU 引擎没有 vsock，用户态网络把宿主的 Unix socket 转发到这个端口；
/// VZ 引擎下宿主直连客户机 NAT 地址。两种情况下宿主都以默认网关的地址出现，所以只接受来自默认网关的连接，
/// 客户机里的其他进程连不进来。
pub struct Listener {
    inner: TcpListener,
}

impl Listener {
    pub fn bind(port: u32) -> io::Result<Self> {
        let port = u16::try_from(port).map_err(io::Error::other)?;
        Ok(Self { inner: TcpListener::bind(("0.0.0.0", port))? })
    }

    pub fn accept(&self) -> io::Result<Conn> {
        loop {
            let (stream, peer) = self.inner.accept()?;
            if super::system::default_gateways().contains(&peer.ip()) {
                stream.set_nodelay(true).ok();
                return Ok(stream);
            }
            drop(stream);
        }
    }
}

