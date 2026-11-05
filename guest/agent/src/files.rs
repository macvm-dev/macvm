//! 文件流的收（`files-put`）与发（`files-get`）。

use macvm_agent_protocol::{self as proto, EntryKind, FileEntry, FileFrame, GuestFile};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 每个数据帧的字节数，在 `MAX_FRAME` 以内。
const CHUNK: usize = proto::MAX_FRAME / 2;

/// 收一段文件流放进已有目录 `dir`，返回各顶层项的存放路径。顶层项与已有项重名时编号；
/// 出错时删掉这次已建的顶层项。Linux 上新建的项归 `dir` 的所有者：代理以 root 运行，而文件是给登录用户的。
pub fn receive(conn: &mut impl Read, dir: &Path) -> io::Result<Vec<GuestFile>> {
    let mut receiver = Receiver::new(dir);
    let result = receiver.run(conn);
    if result.is_err() {
        // Windows 上删不掉还开着的文件，先关掉正在写的那个。
        receiver.open = None;
        for item in &receiver.top {
            let _ = if item.dir { fs::remove_dir_all(&item.path) } else { fs::remove_file(&item.path) };
        }
    }
    result.map(|()| receiver.top)
}

struct Receiver<'a> {
    dir: &'a Path,
    /// 流里顶层项的名字 → 实际存放的路径。
    renamed: HashMap<String, PathBuf>,
    /// 已建的目录（流里的路径）：其他项的上级必须在这里，链接不能当上级，写入不会被链接带到别处。
    dirs: HashSet<String>,
    top: Vec<GuestFile>,
    /// 正在写的文件、剩余字节数与它的条目。
    open: Option<(File, u64, FileEntry)>,
    /// 收完再设的目录权限：先设成只读就写不进内容了。
    dir_modes: Vec<(PathBuf, u32)>,
}

impl<'a> Receiver<'a> {
    fn new(dir: &'a Path) -> Self {
        Self { dir, renamed: HashMap::new(), dirs: HashSet::new(), top: Vec::new(), open: None, dir_modes: Vec::new() }
    }

    fn run(&mut self, conn: &mut impl Read) -> io::Result<()> {
        loop {
            let Some((kind, payload)) = proto::read_file_frame(conn)? else {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "连接在文件流结束前关闭"));
            };
            match kind {
                FileFrame::Entry => {
                    if self.open.is_some() {
                        return Err(invalid("文件内容不足就开始了下一项"));
                    }
                    let entry: FileEntry = serde_json::from_slice(&payload).map_err(|e| invalid(&format!("无法解析文件条目：{e}")))?;
                    self.create(entry)?;
                }
                FileFrame::Data => self.write(&payload)?,
                FileFrame::End => {
                    if self.open.is_some() {
                        return Err(invalid("文件内容不足就结束了"));
                    }
                    for (path, mode) in self.dir_modes.iter().rev() {
                        set_mode(path, *mode | 0o700);
                    }
                    return Ok(());
                }
                FileFrame::Error => return Err(io::Error::other(String::from_utf8_lossy(&payload).into_owned())),
            }
        }
    }

    fn create(&mut self, entry: FileEntry) -> io::Result<()> {
        let parts = proto::split_entry_path(&entry.path).ok_or_else(|| invalid(&format!("不合法的路径：{}", entry.path)))?;
        let path = if let [name] = parts[..] {
            let name = local_name(name);
            let taken = |n: &str| self.dir.join(n).symlink_metadata().is_ok() || self.renamed.values().any(|p| p.file_name() == Some(n.as_ref()));
            let actual = self.dir.join(proto::unique_name(&name, entry.kind == EntryKind::Dir, cfg!(windows), taken));
            self.renamed.insert(parts[0].to_string(), actual.clone());
            self.top.push(GuestFile { path: actual.to_string_lossy().into_owned(), dir: entry.kind == EntryKind::Dir });
            actual
        } else {
            let parent = parts[..parts.len() - 1].join("/");
            if !self.dirs.contains(&parent) {
                return Err(invalid(&format!("{} 的上级不是这次收到的目录", entry.path)));
            }
            parts[1..].iter().fold(self.renamed[parts[0]].clone(), |p, part| p.join(local_name(part)))
        };
        match entry.kind {
            EntryKind::Dir => {
                fs::create_dir(&path)?;
                adopt_owner(&path, self.dir);
                self.dirs.insert(entry.path.clone());
                if let Some(mode) = entry.mode {
                    self.dir_modes.push((path, mode));
                }
            }
            EntryKind::File => {
                let file = File::options().write(true).create_new(true).open(&path)?;
                adopt_owner(&path, self.dir);
                let size = entry.size;
                self.open = Some((file, size, entry));
                if size == 0 {
                    self.finish_file()?;
                }
            }
            EntryKind::Link => make_link(entry.target.as_deref().unwrap_or_default(), &path, self.dir)?,
        }
        Ok(())
    }

    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        let Some((file, left, _)) = self.open.as_mut() else { return Err(invalid("数据帧前没有文件条目")) };
        if data.len() as u64 > *left {
            return Err(invalid("文件内容超过条目里的大小"));
        }
        file.write_all(data)?;
        *left -= data.len() as u64;
        if *left == 0 {
            self.finish_file()?;
        }
        Ok(())
    }

    fn finish_file(&mut self) -> io::Result<()> {
        let Some((file, _, entry)) = self.open.take() else { return Ok(()) };
        if let Some(ms) = entry.mtime_ms {
            let time = if ms >= 0 { UNIX_EPOCH + Duration::from_millis(ms as u64) } else { UNIX_EPOCH - Duration::from_millis(ms.unsigned_abs()) };
            let _ = file.set_modified(time);
        }
        drop(file);
        if let (Some(mode), Some(path)) = (entry.mode, self.local_path(&entry.path)) {
            set_mode(&path, mode);
        }
        Ok(())
    }

    fn local_path(&self, path: &str) -> Option<PathBuf> {
        let parts = proto::split_entry_path(path)?;
        Some(parts[1..].iter().fold(self.renamed.get(parts[0])?.clone(), |p, part| p.join(local_name(part))))
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// 本系统文件名里不能用的字符换成 `_`。Windows 不认 `<>:"/\|?*` 与控制字符、末尾的点与空格，以及 CON、NUL 一类设备名。
fn local_name(name: &str) -> String {
    if !cfg!(windows) {
        return name.to_string();
    }
    let mut out: String = name.chars().map(|c| if c < ' ' || "<>:\"|?*".contains(c) { '_' } else { c }).collect();
    while out.ends_with(['.', ' ']) {
        out.pop();
    }
    let stem = out.split('.').next().unwrap_or_default().to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
        || (stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.as_bytes()[3].is_ascii_digit());
    if out.is_empty() || reserved { format!("_{out}") } else { out }
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode & 0o777));
}

#[cfg(windows)]
fn set_mode(_path: &Path, _mode: u32) {}

#[cfg(target_os = "linux")]
fn adopt_owner(path: &Path, dir: &Path) {
    use std::os::unix::fs::MetadataExt;
    if let Ok(meta) = fs::metadata(dir) {
        let _ = std::os::unix::fs::lchown(path, Some(meta.uid()), Some(meta.gid()));
    }
}

#[cfg(not(target_os = "linux"))]
fn adopt_owner(_path: &Path, _dir: &Path) {}

#[cfg(unix)]
fn make_link(target: &str, path: &Path, dir: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, path)?;
    adopt_owner(path, dir);
    Ok(())
}

/// 普通用户在 Windows 上建不了符号链接，跳过。
#[cfg(windows)]
fn make_link(_target: &str, _path: &Path, _dir: &Path) -> io::Result<()> {
    Ok(())
}

/// 这些路径里普通文件的总字节数，不跟随链接。
pub fn total_size(paths: &[PathBuf]) -> io::Result<u64> {
    let mut total = 0;
    for path in paths {
        walk(path, &mut |_, meta| {
            if meta.is_file() {
                total += meta.len();
            }
            Ok(())
        })?;
    }
    Ok(total)
}

/// 先序遍历 `path`，不跟随链接；目录项按名字排序。
fn walk(path: &Path, visit: &mut dyn FnMut(&Path, &fs::Metadata) -> io::Result<()>) -> io::Result<()> {
    let meta = fs::symlink_metadata(path).map_err(|e| with_path(e, path))?;
    visit(path, &meta)?;
    if meta.is_dir() {
        let mut children: Vec<PathBuf> = fs::read_dir(path).map_err(|e| with_path(e, path))?.map(|e| e.map(|e| e.path())).collect::<io::Result<_>>()?;
        children.sort();
        for child in children {
            walk(&child, visit)?;
        }
    }
    Ok(())
}

fn with_path(e: io::Error, path: &Path) -> io::Error {
    io::Error::new(e.kind(), format!("{}：{e}", path.display()))
}

/// 把这些路径发成一段文件流；出错时发 `error` 帧后返回错误。
pub fn send(conn: &mut impl Write, paths: &[PathBuf]) -> io::Result<()> {
    let result = paths.iter().try_for_each(|path| send_tree(conn, path));
    match result {
        Ok(()) => proto::write_file_frame(conn, FileFrame::End, b""),
        Err(e) => {
            let _ = proto::write_file_frame(conn, FileFrame::Error, e.to_string().as_bytes());
            Err(e)
        }
    }
}

fn send_tree(conn: &mut impl Write, root: &Path) -> io::Result<()> {
    let name = root.file_name().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("{} 没有文件名", root.display())))?;
    let base = root.parent().unwrap_or(root);
    walk(root, &mut |path, meta| {
        let relative: Vec<String> = path.strip_prefix(base).unwrap_or(Path::new(name)).components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
        let kind = if meta.is_dir() {
            EntryKind::Dir
        } else if meta.is_file() {
            EntryKind::File
        } else if meta.file_type().is_symlink() && cfg!(unix) {
            EntryKind::Link
        } else {
            return Ok(());
        };
        let entry = FileEntry {
            path: relative.join("/"),
            kind,
            size: if kind == EntryKind::File { meta.len() } else { 0 },
            mode: unix_mode(meta),
            mtime_ms: meta.modified().ok().map(unix_ms),
            target: if kind == EntryKind::Link { Some(fs::read_link(path)?.to_string_lossy().into_owned()) } else { None },
        };
        // 打开失败时还没发条目，流里不留半个文件。
        let file = if kind == EntryKind::File { Some(File::open(path).map_err(|e| with_path(e, path))?) } else { None };
        proto::write_file_frame(conn, FileFrame::Entry, &serde_json::to_vec(&entry).map_err(io::Error::other)?)?;
        if let Some(file) = file {
            send_content(conn, file, entry.size).map_err(|e| with_path(e, path))?;
        }
        Ok(())
    })
}

/// 正好发 `size` 字节：文件在发送途中变短时报错，变长时只发前 `size` 字节。
fn send_content(conn: &mut impl Write, mut file: File, size: u64) -> io::Result<()> {
    let mut buf = vec![0u8; CHUNK];
    let mut left = size;
    while left > 0 {
        let want = buf.len().min(left as usize);
        let n = file.read(&mut buf[..want])?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "文件在复制途中变短了"));
        }
        proto::write_file_frame(conn, FileFrame::Data, &buf[..n])?;
        left -= n as u64;
    }
    Ok(())
}

#[cfg(unix)]
fn unix_mode(meta: &fs::Metadata) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    Some(meta.permissions().mode() & 0o777)
}

#[cfg(windows)]
fn unix_mode(_meta: &fs::Metadata) -> Option<u32> {
    None
}

fn unix_ms(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(e) => -(e.duration().as_millis() as i64),
    }
}

/// 客户机剪贴板暂存文件的新目录。同一个父目录下以前的暂存都删掉：剪贴板只引用最近一次。
pub fn clipboard_staging() -> io::Result<PathBuf> {
    let base = std::env::temp_dir().join("macvm-clipboard");
    if let Ok(entries) = fs::read_dir(&base) {
        for entry in entries.flatten() {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
    let dir = base.join(unix_ms(SystemTime::now()).to_string());
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// 路径连同是否为目录；读不到的按文件算。
pub fn describe(paths: &[PathBuf]) -> Vec<GuestFile> {
    paths.iter().map(|p| GuestFile { path: p.to_string_lossy().into_owned(), dir: p.is_dir() }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("macvm-files-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn tree_round_trips_and_conflicts_are_numbered() {
        let src = scratch("src");
        fs::create_dir_all(src.join("dir/sub")).unwrap();
        fs::write(src.join("dir/sub/a.txt"), b"hello").unwrap();
        fs::write(src.join("dir/empty"), b"").unwrap();
        fs::write(src.join("big.bin"), vec![7u8; CHUNK * 2 + 3]).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("sub/a.txt", src.join("dir/link")).unwrap();

        let dst = scratch("dst");
        fs::write(dst.join("big.bin"), b"existing").unwrap();
        let paths = [src.join("dir"), src.join("big.bin")];
        assert_eq!(total_size(&paths).unwrap(), 5 + (CHUNK * 2 + 3) as u64);
        let mut stream = Vec::new();
        send(&mut stream, &paths).unwrap();
        let top = receive(&mut &stream[..], &dst).unwrap();

        assert_eq!(top.iter().map(|f| (Path::new(&f.path).file_name().unwrap().to_str().unwrap(), f.dir)).collect::<Vec<_>>(),
                   [("dir", true), (if cfg!(windows) { "big (2).bin" } else { "big 2.bin" }, false)]);
        assert_eq!(fs::read(dst.join("dir/sub/a.txt")).unwrap(), b"hello");
        assert_eq!(fs::read(dst.join("dir/empty")).unwrap(), b"");
        assert_eq!(fs::read(&top[1].path).unwrap().len(), CHUNK * 2 + 3);
        assert_eq!(fs::read(dst.join("big.bin")).unwrap(), b"existing");
        #[cfg(unix)]
        assert_eq!(fs::read_link(dst.join("dir/link")).unwrap(), Path::new("sub/a.txt"));
    }

    fn frame(out: &mut Vec<u8>, entry: FileEntry) {
        proto::write_file_frame(out, FileFrame::Entry, &serde_json::to_vec(&entry).unwrap()).unwrap();
    }

    fn entry(path: &str, kind: EntryKind) -> FileEntry {
        FileEntry { path: path.into(), kind, size: 0, mode: None, mtime_ms: None, target: Some("/etc".into()) }
    }

    #[test]
    fn refuses_to_write_through_links_and_cleans_up() {
        let dst = scratch("evil");
        let mut stream = Vec::new();
        frame(&mut stream, entry("top", EntryKind::Dir));
        frame(&mut stream, entry("top/link", EntryKind::Link));
        frame(&mut stream, entry("top/link/passwd", EntryKind::File));
        proto::write_file_frame(&mut stream, FileFrame::End, b"").unwrap();
        assert!(receive(&mut &stream[..], &dst).is_err());
        assert!(!dst.join("top").exists());

        let mut stream = Vec::new();
        frame(&mut stream, entry("../escape", EntryKind::File));
        assert!(receive(&mut &stream[..], &dst).is_err());
        assert!(fs::read_dir(&dst).unwrap().next().is_none());
    }

    #[test]
    fn sender_error_aborts_receiver() {
        let dst = scratch("abort");
        let mut stream = Vec::new();
        frame(&mut stream, entry("partial", EntryKind::Dir));
        proto::write_file_frame(&mut stream, FileFrame::Error, "磁盘坏了".as_bytes()).unwrap();
        let err = receive(&mut &stream[..], &dst).unwrap_err();
        assert_eq!(err.to_string(), "磁盘坏了");
        assert!(!dst.join("partial").exists());
    }

    #[test]
    fn windows_names_are_made_legal() {
        if cfg!(windows) {
            assert_eq!(local_name("a:b?.txt"), "a_b_.txt");
            assert_eq!(local_name("con.txt"), "_con.txt");
            assert_eq!(local_name("dots..."), "dots");
        } else {
            assert_eq!(local_name("a:b?.txt"), "a:b?.txt");
        }
    }
}
