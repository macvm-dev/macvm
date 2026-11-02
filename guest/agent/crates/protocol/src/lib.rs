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

pub fn write_frame(w: &mut impl Write, kind: FrameKind, payload: &[u8]) -> io::Result<()> {
    let mut header = [0u8; 5];
    header[0] = kind as u8;
    header[1..].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(payload)
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

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../protocol/fixtures");

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
