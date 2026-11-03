mod exec;
mod listener;
mod clipboard;
mod system;

pub use exec::spawn;
pub use listener::{Conn, Listener, shutdown_write};
pub use system::*;

/// UTF-16、以 NUL 结尾，供 Win32 W 系列函数使用。
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
