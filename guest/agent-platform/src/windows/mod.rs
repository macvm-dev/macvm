mod exec;
mod listener;
mod clipboard;
mod cursor;
mod display;
mod dpi;
mod gpu;
mod system;

pub use cursor::{configure_hardware_cursor, restore_system_cursors, watch_cursor};
pub use display::set_display;
pub use dpi::set_display_scale;
pub use gpu::{gpu_driver_package_is, install_gpu_driver, replace_gpu_driver};
pub use exec::spawn;
pub use listener::{Conn, Listener, agent_token, set_read_timeout, shutdown_write};
pub use system::*;

/// virtio-gpu 的 PCI 厂商与设备号，出现在适配器的 PnP ID 与硬件号里。
const VIRTIO_GPU: &str = "VEN_1AF4&DEV_1050";
/// 子进程不创建控制台窗口。
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// UTF-16、以 NUL 结尾，供 Win32 W 系列函数使用。
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 截到第一个 NUL（不含）；没有 NUL 时为整段。
fn until_nul(s: &[u16]) -> &[u16] {
    &s[..s.iter().position(|&c| c == 0).unwrap_or(s.len())]
}
