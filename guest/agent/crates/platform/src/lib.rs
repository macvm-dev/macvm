//! 客户机系统差异：vsock 监听、进程执行、系统信息与管理操作。

#[cfg(not(unix))]
compile_error!("当前只支持 Linux 与 macOS 客户机");

pub mod exec;
pub mod system;
pub mod vsock;
