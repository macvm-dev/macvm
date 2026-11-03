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

/// 宿主经 vsock 连入的连接。
pub type Conn = File;

/// 半关闭写方向；连接的其他克隆仍可读。
pub fn shutdown_write(conn: &Conn) {
    use std::os::fd::AsRawFd;
    // SAFETY: fd 由 conn 持有，shutdown 不改变其所有权。
    unsafe { libc::shutdown(conn.as_raw_fd(), libc::SHUT_WR) };
}

pub struct Listener {
    fd: RawFd,
}

impl Listener {
    pub fn bind(port: u32) -> io::Result<Self> {
        // SAFETY: 参数都是合法常量；返回值在下面检查。
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | cloexec(), 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let listener = Self { fd };
        let addr = SockaddrVm::any(port);
        // SAFETY: addr 是按内核布局定义的 sockaddr_vm，长度与类型一致。
        let rc = unsafe {
            libc::bind(fd, &addr as *const SockaddrVm as *const libc::sockaddr, std::mem::size_of::<SockaddrVm>() as libc::socklen_t)
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd 是刚创建的 socket。
        if unsafe { libc::listen(fd, 64) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(listener)
    }

    pub fn accept(&self) -> io::Result<File> {
        loop {
            // SAFETY: 不需要对端地址，传空指针合法。
            let fd = unsafe { libc::accept(self.fd, std::ptr::null_mut(), std::ptr::null_mut()) };
            if fd >= 0 {
                set_cloexec(fd);
                // SAFETY: accept 返回的 fd 归调用方独占。
                return Ok(unsafe { File::from_raw_fd(fd) });
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: fd 由本对象独占。
        unsafe { libc::close(self.fd) };
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
