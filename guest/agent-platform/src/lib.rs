//! 客户机系统差异：监听宿主连接、执行进程、系统信息与管理操作。各平台实现同一组接口。

use std::fs::File;
use std::io;
use std::process::Command;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

#[cfg(any(windows, test))]
mod cmdline;
mod input;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

/// 运行命令并等它结束，非零退出算错误。
pub(crate) fn run(program: &str, args: &[&str]) -> io::Result<()> {
    let status = Command::new(program).args(args).status()?;
    if status.success() { Ok(()) } else { Err(io::Error::other(format!("{program} exited with an error ({status})"))) }
}

/// 连接的来处。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// vsock，对端是宿主：其他 CID 连入的连接不交出。
    Vsock,
    /// 源地址是默认网关的 TCP。用户态网络与 NAT 下宿主以这个地址出现；桥接网络下它是局域网路由器，地址也能被冒用。
    Gateway,
    /// 其他来源的 TCP：桥接网络下的宿主、客户机里的进程或网上别的机器。
    Network,
}

pub struct ExecOptions<'a> {
    pub argv: &'a [String],
    pub cwd: Option<&'a str>,
    pub env: &'a [(String, String)],
    /// 分配终端时为 (列, 行)。
    pub tty: Option<(u16, u16)>,
    /// 请求指定的执行身份；None 时用 `default_user`，再没有则为代理自身身份。
    pub user: Option<&'a str>,
    pub default_user: Option<&'a str>,
}

/// 进程退出状态：被信号终止时 code 为 128 + 信号。
#[derive(Debug, Clone, Copy)]
pub struct Exit {
    pub code: i32,
    pub signal: Option<i32>,
}

pub trait ChildProcess: Send {
    fn wait(&mut self) -> io::Result<Exit>;
    /// 返回可在任意线程调用的挂断函数，宿主断开时用它结束子进程。本对象释放后再调用不起作用。
    fn hangup(&self) -> io::Result<Box<dyn Fn() + Send + Sync>>;
}

pub enum SpawnedIo {
    /// 终端模式：输入输出可能是同一个句柄（Unix PTY 主端）或两条管道（Windows ConPTY）。
    Pty { input: File, output: File, resize: Box<dyn Fn(u16, u16) + Send + Sync> },
    Pipes { stdin: File, stdout: File, stderr: File },
}

pub struct Spawned {
    pub io: SpawnedIo,
    pub child: Box<dyn ChildProcess>,
}

/// `ui_snapshot` 的范围：`app` 是 pid、进程名或 bundle id，省略时取前台应用。
pub struct SnapshotOptions<'a> {
    pub app: Option<&'a str>,
    pub max_depth: u32,
    pub max_nodes: u32,
}

/// 一次快照遍历的最长时间：应用卡住时每次查询都要等到超时，到时就交出已遍历的部分并标为不完整。
pub(crate) const SNAPSHOT_BUDGET: std::time::Duration = std::time::Duration::from_secs(20);

/// 自上而下逐行的 8 位 RGB 像素编码成 PNG。
#[cfg(any(target_os = "linux", windows))]
pub(crate) fn encode_png(width: u32, height: u32, rgb: &[u8]) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width, height);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    let mut writer = encoder.write_header().map_err(io::Error::other)?;
    writer.write_image_data(rgb).map_err(io::Error::other)?;
    writer.finish().map_err(io::Error::other)?;
    Ok(out)
}

/// 元素编号不在最近一次快照里。
pub(crate) fn stale_element(id: &str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, format!("Element {id} isn't in the latest snapshot; take a new snapshot and try again"))
}

/// 推给宿主的客户机光标。
pub enum GuestCursor {
    /// 宿主不画光标：客户机隐藏了光标，或光标由客户机自己画。
    Hidden,
    /// 系统光标的种类，宿主换成自己的同类光标。
    System(&'static str),
    Image(CursorImage),
}

/// 客户机光标图像：自上而下逐像素 B G R A，非预乘。
pub struct CursorImage {
    pub width: u32,
    pub height: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    pub bgra: Vec<u8>,
}
