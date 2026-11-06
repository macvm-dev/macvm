//! 够 AT-SPI 用的 D-Bus 客户端：Unix socket、EXTERNAL 认证、同步方法调用，小端编解码。

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Byte(u8),
    Bool(bool),
    I16(i16),
    U16(u16),
    I32(i32),
    U32(u32),
    I64(i64),
    U64(u64),
    F64(f64),
    Str(String),
    Path(String),
    Sig(String),
    /// 发送时只用于非空数组：元素签名取第一个元素的。
    Array(Vec<Value>),
    Struct(Vec<Value>),
    Variant(Box<Value>),
    Fd(u32),
}

impl Value {
    pub fn str(&self) -> Option<&str> {
        match self {
            Self::Str(s) | Self::Path(s) | Self::Sig(s) => Some(s),
            Self::Variant(v) => v.str(),
            _ => None,
        }
    }

    pub fn int(&self) -> Option<i64> {
        Some(match self {
            Self::Byte(n) => i64::from(*n),
            Self::I16(n) => i64::from(*n),
            Self::U16(n) => i64::from(*n),
            Self::I32(n) => i64::from(*n),
            Self::U32(n) => i64::from(*n),
            Self::I64(n) => *n,
            Self::U64(n) => *n as i64,
            Self::Variant(v) => return v.int(),
            _ => return None,
        })
    }

    pub fn float(&self) -> Option<f64> {
        match self {
            Self::F64(n) => Some(*n),
            Self::Variant(v) => v.float(),
            other => other.int().map(|n| n as f64),
        }
    }

    pub fn items(&self) -> &[Value] {
        match self {
            Self::Array(v) | Self::Struct(v) => v,
            Self::Variant(v) => v.items(),
            _ => &[],
        }
    }

    fn signature(&self) -> String {
        match self {
            Self::Byte(_) => "y".into(),
            Self::Bool(_) => "b".into(),
            Self::I16(_) => "n".into(),
            Self::U16(_) => "q".into(),
            Self::I32(_) => "i".into(),
            Self::U32(_) => "u".into(),
            Self::I64(_) => "x".into(),
            Self::U64(_) => "t".into(),
            Self::F64(_) => "d".into(),
            Self::Str(_) => "s".into(),
            Self::Path(_) => "o".into(),
            Self::Sig(_) => "g".into(),
            Self::Array(v) => format!("a{}", v.first().map_or("v".into(), Value::signature)),
            Self::Struct(v) => format!("({})", v.iter().map(Value::signature).collect::<String>()),
            Self::Variant(_) => "v".into(),
            Self::Fd(_) => "h".into(),
        }
    }
}

fn alignment(code: u8) -> usize {
    match code {
        b'n' | b'q' => 2,
        b'b' | b'i' | b'u' | b's' | b'o' | b'a' | b'h' => 4,
        b'x' | b't' | b'd' | b'(' | b'{' => 8,
        _ => 1,
    }
}

/// 签名开头的一个完整类型的长度。
fn type_len(sig: &[u8]) -> io::Result<usize> {
    let bad = || io::Error::new(io::ErrorKind::InvalidData, "Invalid D-Bus signature");
    match sig.first().ok_or_else(bad)? {
        b'a' => Ok(1 + type_len(&sig[1..])?),
        open @ (b'(' | b'{') => {
            let close = if *open == b'(' { b')' } else { b'}' };
            let mut i = 1;
            while *sig.get(i).ok_or_else(bad)? != close {
                i += type_len(&sig[i..])?;
            }
            Ok(i + 1)
        }
        _ => Ok(1),
    }
}

#[derive(Default)]
struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    fn pad(&mut self, align: usize) {
        while !self.buf.len().is_multiple_of(align) {
            self.buf.push(0);
        }
    }

    fn u32(&mut self, n: u32) {
        self.pad(4);
        self.buf.extend_from_slice(&n.to_le_bytes());
    }

    fn string(&mut self, s: &str) {
        self.u32(s.len() as u32);
        self.buf.extend_from_slice(s.as_bytes());
        self.buf.push(0);
    }

    fn signature(&mut self, s: &str) {
        self.buf.push(s.len() as u8);
        self.buf.extend_from_slice(s.as_bytes());
        self.buf.push(0);
    }

    fn value(&mut self, v: &Value) {
        match v {
            Value::Byte(n) => self.buf.push(*n),
            Value::Bool(b) => self.u32(u32::from(*b)),
            Value::I16(n) => self.fixed(2, &n.to_le_bytes()),
            Value::U16(n) => self.fixed(2, &n.to_le_bytes()),
            Value::I32(n) => self.fixed(4, &n.to_le_bytes()),
            Value::U32(n) | Value::Fd(n) => self.u32(*n),
            Value::I64(n) => self.fixed(8, &n.to_le_bytes()),
            Value::U64(n) => self.fixed(8, &n.to_le_bytes()),
            Value::F64(n) => self.fixed(8, &n.to_le_bytes()),
            Value::Str(s) | Value::Path(s) => self.string(s),
            Value::Sig(s) => self.signature(s),
            Value::Array(items) => {
                self.u32(0);
                let len_at = self.buf.len() - 4;
                let elem = items.first().map_or(b'v', |i| i.signature().as_bytes()[0]);
                self.pad(alignment(elem));
                let start = self.buf.len();
                for item in items {
                    self.value(item);
                }
                let len = (self.buf.len() - start) as u32;
                self.buf[len_at..len_at + 4].copy_from_slice(&len.to_le_bytes());
            }
            Value::Struct(fields) => {
                self.pad(8);
                for field in fields {
                    self.value(field);
                }
            }
            Value::Variant(inner) => {
                self.signature(&inner.signature());
                self.value(inner);
            }
        }
    }

    fn fixed(&mut self, align: usize, bytes: &[u8]) {
        self.pad(align);
        self.buf.extend_from_slice(bytes);
    }
}

/// 读消息体；对齐按相对消息开头的位置算，所以 `buf` 是整条消息。
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn take(&mut self, align: usize, n: usize) -> io::Result<&[u8]> {
        self.pos = self.pos.next_multiple_of(align);
        let end = self.pos.checked_add(n).filter(|&e| e <= self.buf.len());
        let end = end.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "D-Bus message is truncated"))?;
        let bytes = &self.buf[self.pos..end];
        self.pos = end;
        Ok(bytes)
    }

    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4, 4)?.try_into().unwrap()))
    }

    fn text(&mut self, len: usize) -> io::Result<String> {
        let s = String::from_utf8_lossy(self.take(1, len)?).into_owned();
        self.take(1, 1)?;
        Ok(s)
    }

    fn values(&mut self, sig: &[u8]) -> io::Result<Vec<Value>> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < sig.len() {
            let n = type_len(&sig[i..])?;
            out.push(self.value(&sig[i..i + n])?);
            i += n;
        }
        Ok(out)
    }

    fn value(&mut self, sig: &[u8]) -> io::Result<Value> {
        let fixed = |r: &mut Self, n: usize| -> io::Result<[u8; 8]> {
            let mut out = [0u8; 8];
            out[..n].copy_from_slice(r.take(n, n)?);
            Ok(out)
        };
        Ok(match sig[0] {
            b'y' => Value::Byte(self.take(1, 1)?[0]),
            b'b' => Value::Bool(self.u32()? != 0),
            b'n' => Value::I16(i16::from_le_bytes(fixed(self, 2)?[..2].try_into().unwrap())),
            b'q' => Value::U16(u16::from_le_bytes(fixed(self, 2)?[..2].try_into().unwrap())),
            b'i' => Value::I32(self.u32()? as i32),
            b'u' => Value::U32(self.u32()?),
            b'h' => Value::Fd(self.u32()?),
            b'x' => Value::I64(i64::from_le_bytes(fixed(self, 8)?)),
            b't' => Value::U64(u64::from_le_bytes(fixed(self, 8)?)),
            b'd' => Value::F64(f64::from_le_bytes(fixed(self, 8)?)),
            b's' => {
                let len = self.u32()? as usize;
                Value::Str(self.text(len)?)
            }
            b'o' => {
                let len = self.u32()? as usize;
                Value::Path(self.text(len)?)
            }
            b'g' => {
                let len = usize::from(self.take(1, 1)?[0]);
                Value::Sig(self.text(len)?)
            }
            b'v' => {
                let len = usize::from(self.take(1, 1)?[0]);
                let inner = self.text(len)?;
                if inner.is_empty() || type_len(inner.as_bytes())? != inner.len() {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "Invalid D-Bus variant signature"));
                }
                Value::Variant(Box::new(self.value(inner.as_bytes())?))
            }
            b'a' => {
                let len = self.u32()? as usize;
                let elem = &sig[1..];
                self.pos = self.pos.next_multiple_of(alignment(elem[0]));
                let end = self.pos + len;
                if end > self.buf.len() {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "D-Bus array runs past the end of the message"));
                }
                let mut items = Vec::new();
                while self.pos < end {
                    items.push(self.value(elem)?);
                }
                Value::Array(items)
            }
            b'(' | b'{' => {
                self.pos = self.pos.next_multiple_of(8);
                Value::Struct(self.values(&sig[1..sig.len() - 1])?)
            }
            other => return Err(io::Error::new(io::ErrorKind::InvalidData, format!("Unsupported D-Bus type {}", other as char))),
        })
    }
}

const METHOD_CALL: u8 = 1;
const METHOD_RETURN: u8 = 2;
const ERROR: u8 = 3;
const FIELD_PATH: u8 = 1;
const FIELD_INTERFACE: u8 = 2;
const FIELD_MEMBER: u8 = 3;
const FIELD_ERROR_NAME: u8 = 4;
const FIELD_REPLY_SERIAL: u8 = 5;
const FIELD_DESTINATION: u8 = 6;
const FIELD_SIGNATURE: u8 = 8;
/// 单条消息的长度上限（D-Bus 规范的上限）。
const MAX_MESSAGE: usize = 128 << 20;

pub struct Bus {
    stream: BufReader<UnixStream>,
    serial: u32,
}

/// 等一次调用回复的最长时间：应用卡住时这一个元素算失败，不拖住整次快照。
const CALL_TIMEOUT: Duration = Duration::from_secs(3);

impl Bus {
    /// 连接 `unix:path=…` 或 `unix:abstract=…` 地址，以本进程 uid 认证并注册。
    pub fn connect(address: &str) -> io::Result<Self> {
        let stream = address.split(';').find_map(|a| open(a).transpose()).unwrap_or_else(|| {
            Err(io::Error::new(io::ErrorKind::NotFound, format!("Unsupported D-Bus address: {address}")))
        })?;
        stream.set_read_timeout(Some(CALL_TIMEOUT))?;
        let mut stream = BufReader::new(stream);
        // SAFETY: getuid 没有失败的情况。
        let uid = unsafe { libc::getuid() }.to_string();
        let hex: String = uid.bytes().map(|b| format!("{b:02x}")).collect();
        stream.get_mut().write_all(format!("\0AUTH EXTERNAL {hex}\r\n").as_bytes())?;
        let mut line = String::new();
        stream.read_line(&mut line)?;
        if !line.starts_with("OK ") {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("Couldn't authenticate with D-Bus: {}", line.trim())));
        }
        stream.get_mut().write_all(b"BEGIN\r\n")?;
        let mut bus = Self { stream, serial: 0 };
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", &[])?;
        Ok(bus)
    }

    /// 同步调用，返回回复的各个参数；对方回错误时报错。期间收到的信号与过期回复都丢弃。
    pub fn call(&mut self, destination: &str, path: &str, interface: &str, member: &str, args: &[Value]) -> io::Result<Vec<Value>> {
        self.serial += 1;
        let serial = self.serial;
        let message = encode_call(serial, destination, path, interface, member, args);
        self.stream.get_mut().write_all(&message)?;
        loop {
            let message = self.read_message()?;
            let Some(reply) = decode(&message)? else { continue };
            if reply.reply_serial != Some(serial) {
                continue;
            }
            return match reply.kind {
                METHOD_RETURN => Ok(reply.body),
                _ => {
                    let detail = reply.body.first().and_then(Value::str).unwrap_or_default().to_string();
                    let name = reply.error_name.unwrap_or_default();
                    let kind = if name.ends_with("UnknownObject") || name.ends_with("UnknownMethod") || name.ends_with("ServiceUnknown") {
                        io::ErrorKind::NotFound
                    } else {
                        io::ErrorKind::Other
                    };
                    Err(io::Error::new(kind, format!("{member}: {name} {detail}")))
                }
            };
        }
    }

    /// `org.freedesktop.DBus.Properties.Get` 的值（去掉外层变体）。
    pub fn property(&mut self, destination: &str, path: &str, interface: &str, name: &str) -> io::Result<Value> {
        let reply = self.call(destination, path, "org.freedesktop.DBus.Properties", "Get", &[Value::Str(interface.into()), Value::Str(name.into())])?;
        match reply.into_iter().next() {
            Some(Value::Variant(v)) => Ok(*v),
            _ => Err(io::Error::new(io::ErrorKind::InvalidData, format!("Invalid reply to {name}"))),
        }
    }

    fn read_message(&mut self) -> io::Result<Vec<u8>> {
        let mut head = [0u8; 16];
        self.stream.read_exact(&mut head)?;
        if head[0] != b'l' {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Only little-endian D-Bus messages are supported"));
        }
        let body_len = u32::from_le_bytes(head[4..8].try_into().unwrap()) as usize;
        let fields_len = u32::from_le_bytes(head[12..16].try_into().unwrap()) as usize;
        let total = (16 + fields_len).next_multiple_of(8) + body_len;
        if total > MAX_MESSAGE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "D-Bus message is too large"));
        }
        let mut message = head.to_vec();
        message.resize(total, 0);
        self.stream.read_exact(&mut message[16..])?;
        Ok(message)
    }
}

fn open(address: &str) -> io::Result<Option<UnixStream>> {
    let Some(params) = address.strip_prefix("unix:") else { return Ok(None) };
    for param in params.split(',') {
        if let Some(path) = param.strip_prefix("path=") {
            return UnixStream::connect(unescape(path)).map(Some);
        }
        #[cfg(target_os = "linux")]
        if let Some(name) = param.strip_prefix("abstract=") {
            use std::os::linux::net::SocketAddrExt;
            let addr = std::os::unix::net::SocketAddr::from_abstract_name(unescape(name).as_bytes())?;
            return UnixStream::connect_addr(&addr).map(Some);
        }
    }
    Ok(None)
}

/// 地址里的值用 `%xx` 转义。
fn unescape(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(n) = value.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(n);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn encode_call(serial: u32, destination: &str, path: &str, interface: &str, member: &str, args: &[Value]) -> Vec<u8> {
    let mut body = Writer::default();
    for arg in args {
        body.value(arg);
    }
    let signature: String = args.iter().map(Value::signature).collect();
    let mut fields = vec![
        Value::Struct(vec![Value::Byte(FIELD_PATH), Value::Variant(Box::new(Value::Path(path.into())))]),
        Value::Struct(vec![Value::Byte(FIELD_INTERFACE), Value::Variant(Box::new(Value::Str(interface.into())))]),
        Value::Struct(vec![Value::Byte(FIELD_MEMBER), Value::Variant(Box::new(Value::Str(member.into())))]),
        Value::Struct(vec![Value::Byte(FIELD_DESTINATION), Value::Variant(Box::new(Value::Str(destination.into())))]),
    ];
    if !signature.is_empty() {
        fields.push(Value::Struct(vec![Value::Byte(FIELD_SIGNATURE), Value::Variant(Box::new(Value::Sig(signature)))]));
    }
    let mut message = Writer { buf: vec![b'l', METHOD_CALL, 0, 1] };
    message.u32(body.buf.len() as u32);
    message.u32(serial);
    message.value(&Value::Array(fields));
    message.pad(8);
    message.buf.extend_from_slice(&body.buf);
    message.buf
}

struct Reply {
    kind: u8,
    reply_serial: Option<u32>,
    error_name: Option<String>,
    body: Vec<Value>,
}

/// 解出回复或错误；其他类型的消息返回 None。
fn decode(message: &[u8]) -> io::Result<Option<Reply>> {
    let kind = message[1];
    if kind != METHOD_RETURN && kind != ERROR {
        return Ok(None);
    }
    let mut reader = Reader { buf: message, pos: 12 };
    let fields = reader.value(b"a(yv)")?;
    let mut reply = Reply { kind, reply_serial: None, error_name: None, body: Vec::new() };
    let mut signature = String::new();
    for field in fields.items() {
        let [Value::Byte(code), value] = field.items() else { continue };
        match *code {
            FIELD_REPLY_SERIAL => reply.reply_serial = value.int().map(|n| n as u32),
            FIELD_ERROR_NAME => reply.error_name = value.str().map(str::to_owned),
            FIELD_SIGNATURE => signature = value.str().unwrap_or_default().to_owned(),
            _ => {}
        }
    }
    reader.pos = reader.pos.next_multiple_of(8);
    reply.body = reader.values(signature.as_bytes())?;
    Ok(Some(reply))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_encoding_matches_spec_layout() {
        let message = encode_call(7, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", &[]);
        assert_eq!(&message[..4], &[b'l', 1, 0, 1]);
        assert_eq!(u32::from_le_bytes(message[4..8].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(message[8..12].try_into().unwrap()), 7);
        assert!(message.len().is_multiple_of(8));
        let mut reader = Reader { buf: &message, pos: 12 };
        let fields = reader.value(b"a(yv)").unwrap();
        assert_eq!(fields.items().len(), 4);
        assert_eq!(fields.items()[2].items()[1].str(), Some("GetAddress"));
    }

    #[test]
    fn values_round_trip() {
        let args = vec![
            Value::Str("org.a11y.Status".into()),
            Value::I32(-3),
            Value::Variant(Box::new(Value::Bool(true))),
            Value::Array(vec![Value::Struct(vec![Value::Str(":1.5".into()), Value::Path("/a/b".into())])]),
            Value::F64(1.5),
            Value::Array(vec![Value::U32(1), Value::U32(1 << 31)]),
        ];
        let mut w = Writer::default();
        for a in &args {
            w.value(a);
        }
        let sig: String = args.iter().map(Value::signature).collect();
        assert_eq!(sig, "siva(so)dau");
        let mut r = Reader { buf: &w.buf, pos: 0 };
        assert_eq!(r.values(sig.as_bytes()).unwrap(), args);
    }

    #[test]
    fn decodes_error_reply() {
        // 回复头：类型 3，reply serial 9，错误名，签名 s，消息体一个字符串。
        let mut body = Writer::default();
        body.value(&Value::Str("no such object".into()));
        let fields = Value::Array(vec![
            Value::Struct(vec![Value::Byte(FIELD_ERROR_NAME), Value::Variant(Box::new(Value::Str("org.freedesktop.DBus.Error.UnknownObject".into())))]),
            Value::Struct(vec![Value::Byte(FIELD_REPLY_SERIAL), Value::Variant(Box::new(Value::U32(9)))]),
            Value::Struct(vec![Value::Byte(FIELD_SIGNATURE), Value::Variant(Box::new(Value::Sig("s".into())))]),
        ]);
        let mut m = Writer { buf: vec![b'l', ERROR, 1, 1] };
        m.u32(body.buf.len() as u32);
        m.u32(3);
        m.value(&fields);
        m.pad(8);
        m.buf.extend_from_slice(&body.buf);
        let reply = decode(&m.buf).unwrap().unwrap();
        assert_eq!(reply.reply_serial, Some(9));
        assert_eq!(reply.body, [Value::Str("no such object".into())]);
    }

    #[test]
    fn address_unescape() {
        assert_eq!(unescape("/run/user/1000/at-spi/bus%5f0"), "/run/user/1000/at-spi/bus_0");
    }
}
