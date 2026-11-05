//! `files-put`、`files-get` 之后的文件流，以及 `clipboard-get`、`drag-files` 响应里的文件列表。

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

/// `files-put` 把文件放到哪里。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PutTarget {
    /// 请求里 `path` 指定的已有目录。
    Dir,
    /// 投放点下的文件夹窗口或桌面，认不出时为桌面。
    Drop,
    /// 新的暂存目录，收完后把客户机剪贴板换成这些文件。
    Clipboard,
}

/// 客户机上的一个文件或目录。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuestFile {
    /// 客户机上的绝对路径。
    pub path: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub dir: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// 文件流的帧类型；帧格式与 exec 帧相同（`u8 类型 | u32 小端长度 | 载荷`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FileFrame {
    /// 载荷是 `FileEntry` 的 JSON。
    Entry = 0,
    /// 上一个 `file` 条目的内容，合计正好 `size` 字节。
    Data = 1,
    /// 流正常结束，载荷为空。
    End = 2,
    /// 发送方中止，载荷是 UTF-8 的原因。
    Error = 3,
}

impl FileFrame {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Entry,
            1 => Self::Data,
            2 => Self::End,
            3 => Self::Error,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EntryKind {
    Dir,
    File,
    Link,
}

/// 文件流里的一项。先序排列：目录在其内容之前。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileEntry {
    /// 以 `/` 分隔的相对路径，第一段是顶层项的名字；见 `split_entry_path`。
    pub path: String,
    pub kind: EntryKind,
    /// `file` 的字节数。
    #[serde(default, skip_serializing_if = "is_zero")]
    pub size: u64,
    /// Unix 权限位（`0o777` 以内）；接收方是 Windows 时忽略。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<u32>,
    /// 修改时间（Unix 毫秒）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mtime_ms: Option<i64>,
    /// `link` 指向的路径，原样保存。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// 拆开条目路径；空段、`.`、`..`、含 `\` 或 NUL 的段都不合法，返回 None。
pub fn split_entry_path(path: &str) -> Option<Vec<&str>> {
    let parts: Vec<&str> = path.split('/').collect();
    let valid = |p: &&str| !p.is_empty() && *p != "." && *p != ".." && !p.contains(['\\', '\0']);
    parts.iter().all(valid).then_some(parts)
}

/// 目录 `exists` 里已有同名项时，按系统习惯给 `name` 编号：`a.txt` → `a 2.txt`，Windows 上为 `a (2).txt`。
/// 目录与以点开头、没有其他点的名字不拆扩展名。
pub fn unique_name(name: &str, is_dir: bool, windows_style: bool, exists: impl Fn(&str) -> bool) -> String {
    if !exists(name) {
        return name.to_string();
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if !is_dir && i > 0 => name.split_at(i),
        _ => (name, ""),
    };
    (2..)
        .map(|n| if windows_style { format!("{stem} ({n}){ext}") } else { format!("{stem} {n}{ext}") })
        .find(|candidate| !exists(candidate))
        .expect("编号总能找到空位")
}

/// 帧头与载荷一次写出。
pub fn write_file_frame(w: &mut impl Write, kind: FileFrame, payload: &[u8]) -> io::Result<()> {
    crate::write_raw_frame(w, kind as u8, payload)
}

/// 对端正常关闭时返回 `Ok(None)`。
pub fn read_file_frame(r: &mut impl Read) -> io::Result<Option<(FileFrame, Vec<u8>)>> {
    let Some((kind, payload)) = crate::read_raw_frame(r)? else { return Ok(None) };
    let kind = FileFrame::from_u8(kind).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "未知文件流帧类型"))?;
    Ok(Some((kind, payload)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_escaping_paths() {
        assert_eq!(split_entry_path("a/b c/d.txt"), Some(vec!["a", "b c", "d.txt"]));
        for bad in ["", "/a", "a/", "a//b", "../a", "a/../b", "a/./b", ".", "a\\b", "a\0"] {
            assert_eq!(split_entry_path(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn numbers_conflicting_names() {
        let taken = ["a.txt", "a 2.txt", "a (2).txt", "dir.d", ".profile", "x"];
        let exists = |n: &str| taken.contains(&n);
        assert_eq!(unique_name("b.txt", false, false, exists), "b.txt");
        assert_eq!(unique_name("a.txt", false, false, exists), "a 3.txt");
        assert_eq!(unique_name("a.txt", false, true, exists), "a (3).txt");
        assert_eq!(unique_name("dir.d", true, false, exists), "dir.d 2");
        assert_eq!(unique_name(".profile", false, false, exists), ".profile 2");
        assert_eq!(unique_name("x", false, true, exists), "x (2)");
    }

    #[test]
    fn entries_round_trip() {
        let entry = FileEntry { path: "a/b".into(), kind: EntryKind::File, size: 3, mode: Some(0o644), mtime_ms: Some(1), target: None };
        let mut buf = Vec::new();
        write_file_frame(&mut buf, FileFrame::Entry, &serde_json::to_vec(&entry).unwrap()).unwrap();
        write_file_frame(&mut buf, FileFrame::Data, b"abc").unwrap();
        write_file_frame(&mut buf, FileFrame::End, b"").unwrap();
        let mut r = &buf[..];
        let (kind, payload) = read_file_frame(&mut r).unwrap().unwrap();
        assert_eq!((kind, serde_json::from_slice::<FileEntry>(&payload).unwrap()), (FileFrame::Entry, entry));
        assert_eq!(read_file_frame(&mut r).unwrap(), Some((FileFrame::Data, b"abc".to_vec())));
        assert_eq!(read_file_frame(&mut r).unwrap(), Some((FileFrame::End, vec![])));
        assert_eq!(read_file_frame(&mut r).unwrap(), None);
    }
}
