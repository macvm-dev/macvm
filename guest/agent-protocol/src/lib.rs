//! 宿主与 macvm-agent 之间的消息类型与 exec 帧编解码。

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{self, Read, Write};

/// 代理监听的 vsock 端口。
pub const PORT: u32 = 6100;
/// 单帧载荷上限。
pub const MAX_FRAME: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Request {
    Info,
    Exec(ExecRequest),
    Forward { port: u16 },
    Shutdown {
        #[serde(default)]
        reboot: bool,
    },
    SetTime { unix_ms: i64 },
    ClipboardGet,
    ClipboardSet { text: String },
    Mount {
        tag: String,
        path: String,
        #[serde(default)]
        read_only: bool,
    },
    /// 宿主改变了显示输出尺寸，客户机桌面跟着切换。
    Display { width: u32, height: u32 },
    /// 桌面缩放比例（百分比），取不超过它的最接近档位。
    DisplayScale { percent: u32 },
    /// 成功响应后，代理每当客户机光标变化就发一行 `CursorShape`，直到连接关闭。
    CursorWatch,
    /// 宿主带的 Windows 显卡驱动包（zip）的 SHA-256 与字节数；代理已有同一个包时回 `current`，
    /// 否则回 `send`，收下随后的 `size` 字节、安装后再回一行（`installed` 或 `unchanged`）。
    GpuDriver { sha256: String, size: u64 },
    /// 把客户机的文件页缓存回收到约 `keep` 字节（仅 Linux）。
    TrimCache { keep: u64 },
}

/// 客户机当前光标：`bgra` 为逐像素 B G R A（非预乘）的 Base64，自上而下；`hidden` 时其余字段无意义；
/// 有 `system` 时是该种系统光标，没有图像。
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct CursorShape {
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
    #[serde(default)]
    pub hot_x: u32,
    #[serde(default)]
    pub hot_y: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub bgra: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
}

/// 标准 Base64（带填充）。
pub fn base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExecRequest {
    pub argv: Vec<String>,
    /// 执行身份；省略时为代理的默认用户。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub tty: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Info {
    pub version: String,
    pub os: String,
    pub hostname: String,
    pub ipv4: Vec<String>,
    pub mem_total: u64,
    pub mem_available: u64,
    pub uptime_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub info: Option<Info>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

impl Response {
    pub fn ok() -> Self {
        Self { ok: true, ..Default::default() }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self { ok: false, error: Some(message.into()), ..Default::default() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameKind {
    Stdin = 0,
    Stdout = 1,
    Stderr = 2,
    Resize = 3,
    Exit = 4,
    StdinEof = 5,
}

impl FrameKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Stdin,
            1 => Self::Stdout,
            2 => Self::Stderr,
            3 => Self::Resize,
            4 => Self::Exit,
            5 => Self::StdinEof,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowSize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExitStatus {
    pub code: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<i32>,
}

/// 帧头与载荷一次写出：连接开了 TCP_NODELAY 时，分两次写会把 5 字节的帧头单独发成一个包。
pub fn write_frame(w: &mut impl Write, kind: FrameKind, payload: &[u8]) -> io::Result<()> {
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.push(kind as u8);
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.extend_from_slice(payload);
    w.write_all(&frame)
}

/// 对端正常关闭时返回 `Ok(None)`。
pub fn read_frame(r: &mut impl Read) -> io::Result<Option<(FrameKind, Vec<u8>)>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let kind = FrameKind::from_u8(header[0]).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "未知帧类型"))?;
    let len = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "帧过大"));
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload)?;
    Ok(Some((kind, payload)))
}

/// 读一行请求（不含换行），上限 1 MiB。
pub fn read_line(r: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if r.read(&mut byte)? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "连接在请求行结束前关闭"));
        }
        if byte[0] == b'\n' {
            return Ok(line);
        }
        line.push(byte[0]);
        if line.len() > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "请求行过长"));
        }
    }
}

pub fn write_json_line(w: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    let mut data = serde_json::to_vec(value).map_err(io::Error::other)?;
    data.push(b'\n');
    w.write_all(&data)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures");

    #[test]
    fn requests_round_trip() {
        let text = std::fs::read_to_string(format!("{FIXTURES}/requests.jsonl")).unwrap();
        for line in text.lines().filter(|l| !l.is_empty()) {
            let req: Request = serde_json::from_str(line).unwrap_or_else(|e| panic!("{line}: {e}"));
            let again: Request = serde_json::from_str(&serde_json::to_string(&req).unwrap()).unwrap();
            assert_eq!(req, again);
        }
    }

    #[test]
    fn responses_round_trip() {
        let text = std::fs::read_to_string(format!("{FIXTURES}/responses.jsonl")).unwrap();
        for line in text.lines().filter(|l| !l.is_empty()) {
            let resp: Response = serde_json::from_str(line).unwrap_or_else(|e| panic!("{line}: {e}"));
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(serde_json::to_value(&resp).unwrap(), value, "{line}");
        }
    }

    #[test]
    fn cursor_shapes_round_trip() {
        let text = std::fs::read_to_string(format!("{FIXTURES}/cursors.jsonl")).unwrap();
        for line in text.lines().filter(|l| !l.is_empty()) {
            let shape: CursorShape = serde_json::from_str(line).unwrap_or_else(|e| panic!("{line}: {e}"));
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(serde_json::to_value(&shape).unwrap(), value, "{line}");
        }
    }

    #[test]
    fn frames_round_trip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, FrameKind::Stdout, b"hello").unwrap();
        write_frame(&mut buf, FrameKind::StdinEof, b"").unwrap();
        let mut r = &buf[..];
        assert_eq!(read_frame(&mut r).unwrap(), Some((FrameKind::Stdout, b"hello".to_vec())));
        assert_eq!(read_frame(&mut r).unwrap(), Some((FrameKind::StdinEof, vec![])));
        assert_eq!(read_frame(&mut r).unwrap(), None);
    }
}

#[cfg(test)]
mod base64_tests {
    #[test]
    fn encodes_with_padding() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }
}
