//! 客户机系统差异：监听宿主连接、执行进程、系统信息与管理操作。各平台实现同一组接口。

use std::fs::File;
use std::io;
use std::process::Command;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

/// 运行命令并等它结束，非零退出算错误。
pub(crate) fn run(program: &str, args: &[&str]) -> io::Result<()> {
    let status = Command::new(program).args(args).status()?;
    if status.success() { Ok(()) } else { Err(io::Error::other(format!("{program} 退出码 {status}"))) }
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
