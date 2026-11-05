// 编解码不依赖 Linux，测试在任何宿主上都跑。
#[cfg(any(target_os = "linux", test))]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod dbus;
#[cfg(target_os = "linux")]
mod drm;
mod exec;
mod listener;
#[cfg(target_os = "macos")]
mod pasteboard_macos;
#[cfg(target_os = "linux")]
mod session;
mod system;
#[cfg(target_os = "linux")]
mod uinput;
#[cfg(target_os = "linux")]
mod ui_linux;
#[cfg(target_os = "macos")]
mod ui_macos;

pub use exec::spawn;
#[cfg(target_os = "macos")]
pub use pasteboard_macos::{clipboard_files, clipboard_set_files, drag_files};
pub use listener::{Conn, Listener, agent_token, peer_closed, set_read_timeout, shutdown_write};
pub use system::*;
#[cfg(target_os = "linux")]
pub use ui_linux::{prepare_ui_input, run_ui_helper, ui_action, ui_element_bounds, ui_input, ui_screenshot, ui_snapshot};
#[cfg(target_os = "macos")]
pub use ui_macos::{UI_GRANT_ARG, drop_dir, run_ui_grant_check, ui_action, ui_element_bounds, ui_input, ui_screenshot, ui_snapshot};
