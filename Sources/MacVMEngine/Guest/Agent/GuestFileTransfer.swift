public import Foundation
public import MacVMModel

/// 经客户机代理在宿主与客户机之间复制文件与目录（`files-put`、`files-get`），保留目录结构、符号链接、权限位与修改时间。
/// 要求代理支持 `AgentProtocol.featureFiles`。进度记在传入的 `Progress` 上（单位是字节），取消它即中止复制并抛出 `CancellationError`。
public enum GuestFileTransfer {
    /// 每次读写等待的上限：复制本身可以很久，但连接停住这么久就算断了。
    private static let timeout = 60
    /// 每个数据帧的字节数，在 `AgentProtocol.maxFrame` 以内。
    private static let chunk = AgentProtocol.maxFrame / 2

    /// 客户机里文件的总量超过 `receive` 的上限。
    public struct TooLarge: Error, Sendable {
        public let total: Int64
    }

    /// 代理是否支持复制文件；连不上代理时为 false。
    public static func isSupported(_ bundle: VMBundle) -> Bool {
        (try? AgentClient.info(bundle, timeout: 3))?.features?.contains(AgentProtocol.featureFiles) == true
    }

    public static func requireSupport(_ bundle: VMBundle) throws {
        guard try bundle.loadConfig().guestAgent else {
            throw MacVMError.unsupported(String(l10n: "The guest agent isn't installed in \(bundle.name); run macvm agent install \(bundle.name) first"))
        }
        guard try AgentClient.info(bundle).features?.contains(AgentProtocol.featureFiles) == true else {
            throw MacVMError.unsupported(String(l10n: "The guest agent in \(bundle.name) is too old to copy files; update it with macvm agent install \(bundle.name)"))
        }
    }

    /// 这些文件与目录里普通文件的总字节数，不跟随符号链接。
    public static func totalSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            try? walk(url) { _, info in
                if info.kind == .file { total += info.size }
            }
        }
        return total
    }

    /// 把宿主上的这些文件与目录复制到客户机，返回各顶层项在客户机上的路径。与客户机已有项重名的顶层项由代理编号改名。
    @discardableResult
    public static func send(_ urls: [URL], to target: AgentProtocol.PutTarget, bundle: VMBundle, progress: Progress) throws -> [AgentProtocol.GuestFile] {
        progress.totalUnitCount = totalSize(urls)
        let (response, socket) = try AgentClient.open(.filesPut(target), bundle: bundle, timeout: timeout)
        _ = try response.checked(String(l10n: "Couldn't copy"))
        do {
            for url in urls { try sendTree(url, over: socket, progress: progress) }
            try socket.writeAll(ExecSession.frame(AgentProtocol.FileFrame.end.rawValue, Data()))
        } catch let error as CancellationError {
            throw error
        } catch {
            // 代理收不下去时先回失败响应再断开，它的原因比本地写失败更有用。
            if let line = try? socket.readLine(), let reply = try? JSONDecoder().decode(AgentProtocol.Response.self, from: line) {
                _ = try reply.checked(String(l10n: "Couldn't copy"))
            }
            throw error
        }
        guard let line = try socket.readLine() else { throw MacVMError.io(String(l10n: "The guest agent disconnected before the copy finished")) }
        return try JSONDecoder().decode(AgentProtocol.Response.self, from: line).checked(String(l10n: "Couldn't copy")).files ?? []
    }

    /// 把客户机上的这些路径复制到宿主目录 `directory`，返回各顶层项在宿主上的位置。与已有项重名的顶层项编号改名；
    /// 出错或取消时删掉这次已建的顶层项。客户机里文件总量超过 `limit` 字节时什么都不复制，抛出 `TooLarge`。
    @discardableResult
    public static func receive(_ paths: [String], into directory: URL, bundle: VMBundle, progress: Progress, limit: Int64? = nil) throws -> [URL] {
        let (response, socket) = try AgentClient.open(.filesGet(paths: paths), bundle: bundle, timeout: timeout)
        let total = try response.checked(String(l10n: "Couldn't copy")).total ?? 0
        if let limit, total > limit { throw TooLarge(total: total) }
        progress.totalUnitCount = total
        var receiver = Receiver(directory: directory)
        do {
            try receiver.run(socket, progress: progress)
        } catch {
            receiver.removeCreated()
            throw error
        }
        return receiver.top
    }

    // MARK: - 发送

    private struct ItemInfo {
        enum Kind { case dir, file, link, other }
        let kind: Kind
        let size: Int64
        let mode: UInt16
        let mtime: Int64?
    }

    private static func info(_ path: String) throws -> ItemInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw MacVMError.posix(path) }
        let kind: ItemInfo.Kind = switch st.st_mode & S_IFMT {
        case S_IFDIR: .dir
        case S_IFREG: .file
        case S_IFLNK: .link
        default: .other
        }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
        return ItemInfo(kind: kind, size: Int64(st.st_size), mode: UInt16(st.st_mode) & 0o777, mtime: mtime)
    }

    /// 先序遍历 `root`，不跟随符号链接；目录项按名字排序。`visit` 拿到的相对路径以 `root` 的名字开头。
    private static func walk(_ root: URL, _ visit: ([String], ItemInfo) throws -> Void) throws {
        func recurse(_ path: String, _ relative: [String]) throws {
            let item = try info(path)
            try visit(relative, item)
            guard item.kind == .dir else { return }
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                try recurse(path + "/" + name, relative + [name])
            }
        }
        let path = root.standardizedFileURL.path
        try recurse(path, [(path as NSString).lastPathComponent])
    }

    private static func sendTree(_ root: URL, over socket: UnixSocket, progress: Progress) throws {
        let base = root.standardizedFileURL.deletingLastPathComponent().path
        try walk(root) { relative, item in
            if progress.isCancelled { throw CancellationError() }
            let path = (base as NSString).appendingPathComponent(relative.joined(separator: "/"))
            let entry: AgentProtocol.FileEntry
            var handle: FileHandle?
            switch item.kind {
            case .dir: entry = .init(path: relative.joined(separator: "/"), kind: .dir, mode: item.mode, mtime_ms: item.mtime)
            case .file:
                // 打开失败时还没发条目，流里不留半个文件。
                guard let opened = FileHandle(forReadingAtPath: path) else { throw MacVMError.io(String(l10n: "Couldn't read \(path)")) }
                handle = opened
                entry = .init(path: relative.joined(separator: "/"), kind: .file, size: item.size, mode: item.mode, mtime_ms: item.mtime)
            case .link:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                entry = .init(path: relative.joined(separator: "/"), kind: .link, mode: item.mode, mtime_ms: item.mtime, target: target)
            case .other: return
            }
            try socket.writeAll(ExecSession.frame(AgentProtocol.FileFrame.entry.rawValue, JSONEncoder().encode(entry)))
            guard let handle else { return }
            defer { try? handle.close() }
            var left = item.size
            while left > 0 {
                if progress.isCancelled { throw CancellationError() }
                let data = try handle.read(upToCount: min(chunk, Int(left))) ?? Data()
                guard !data.isEmpty else { throw MacVMError.io(String(l10n: "\(path) shrank while it was being copied")) }
                try socket.writeAll(ExecSession.frame(AgentProtocol.FileFrame.data.rawValue, data))
                left -= Int64(data.count)
                progress.completedUnitCount += Int64(data.count)
            }
        }
    }

    // MARK: - 接收

    /// 把文件流写进 `directory`。其他项的上级必须是这次收到的目录，链接不能当上级，客户机发来的路径写不到目录之外。
    private struct Receiver {
        let directory: URL
        private(set) var top: [URL] = []
        /// 流里顶层项的名字 → 实际存放的位置。
        private var renamed: [String: URL] = [:]
        private var dirs: Set<String> = []
        /// 收完再设的目录权限：先设成只读就写不进内容了。
        private var dirModes: [(URL, UInt16)] = []
        private var open: (handle: FileHandle, left: Int64, entry: AgentProtocol.FileEntry, url: URL)?

        init(directory: URL) { self.directory = directory }

        mutating func run(_ socket: UnixSocket, progress: Progress) throws {
            while true {
                if progress.isCancelled { throw CancellationError() }
                guard let header = try socket.readExact(5) else { throw MacVMError.io(String(l10n: "The guest agent disconnected before the copy finished")) }
                let length = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
                guard length <= AgentProtocol.maxFrame, let payload = try socket.readExact(length) else {
                    throw MacVMError.io(String(l10n: "The guest agent sent an invalid file stream"))
                }
                switch AgentProtocol.FileFrame(rawValue: header[0]) {
                case .entry:
                    guard open == nil else { throw invalid(String(l10n: "the next entry started before the current file was complete")) }
                    try create(JSONDecoder().decode(AgentProtocol.FileEntry.self, from: payload))
                case .data:
                    try write(payload)
                    progress.completedUnitCount += Int64(payload.count)
                case .end:
                    guard open == nil else { throw invalid(String(l10n: "the stream ended before the last file was complete")) }
                    for (url, mode) in dirModes.reversed() { chmod(url.path, mode_t(mode & 0o777 | 0o700)) }
                    return
                case .error: throw MacVMError.engine(String(l10n: "Guest agent: \(String(decoding: payload, as: UTF8.self))"))
                case nil: throw invalid(String(l10n: "unknown file stream frame type"))
                }
            }
        }

        private func invalid(_ message: String) -> MacVMError { .io(String(l10n: "The guest agent sent an invalid file stream: \(message)")) }

        private mutating func create(_ entry: AgentProtocol.FileEntry) throws {
            guard let parts = AgentProtocol.FileEntry.split(entry.path) else { throw invalid(String(l10n: "invalid path \(entry.path)")) }
            let url: URL
            if parts.count == 1 {
                let taken = Set(renamed.values.map(\.lastPathComponent))
                let name = GuestFileTransfer.uniqueName(parts[0], isDirectory: entry.kind == .dir) { name in
                    taken.contains(name) || (try? FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)) != nil
                }
                url = directory.appending(path: name, directoryHint: entry.kind == .dir ? .isDirectory : .notDirectory)
                renamed[parts[0]] = url
                top.append(url)
            } else {
                guard dirs.contains(parts.dropLast().joined(separator: "/")), let root = renamed[parts[0]] else {
                    throw invalid(String(l10n: "the parent folder of \(entry.path) wasn't part of this transfer"))
                }
                url = parts.dropFirst().reduce(root) { $0.appending(path: $1) }
            }
            switch entry.kind {
            case .dir:
                guard mkdir(url.path, 0o700) == 0 else { throw MacVMError.posix(url.path) }
                dirs.insert(entry.path)
                dirModes.append((url, entry.mode ?? 0o755))
            case .file:
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MacVMError.posix(url.path) }
                open = (FileHandle(fileDescriptor: fd, closeOnDealloc: true), entry.size, entry, url)
                if entry.size == 0 { try finishFile() }
            case .link:
                guard symlink(entry.target ?? "", url.path) == 0 else { throw MacVMError.posix(url.path) }
            }
        }

        private mutating func write(_ data: Data) throws {
            guard let current = open else { throw invalid(String(l10n: "got a data frame before any file entry")) }
            guard Int64(data.count) <= current.left else { throw invalid(String(l10n: "a file is larger than its entry says")) }
            try current.handle.write(contentsOf: data)
            open?.left -= Int64(data.count)
            if open?.left == 0 { try finishFile() }
        }

        private mutating func finishFile() throws {
            guard let current = open else { return }
            open = nil
            fchmod(current.handle.fileDescriptor, mode_t((current.entry.mode ?? 0o644) & 0o777))
            if let ms = current.entry.mtime_ms, ms >= 0 {
                var times = [timespec(tv_sec: time_t(ms / 1000), tv_nsec: Int((ms % 1000) * 1_000_000))]
                times.append(times[0])
                futimens(current.handle.fileDescriptor, times)
            }
            try current.handle.close()
        }

        func removeCreated() {
            for url in top { try? FileManager.default.removeItem(at: url) }
        }

    }

    /// 已有同名项时按访达的习惯编号：`a.txt` → `a 2.txt`；目录与以点开头、没有其他点的名字不拆扩展名。
    static func uniqueName(_ name: String, isDirectory: Bool, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let (stem, ext): (String, String) = if !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            (String(name[..<dot]), String(name[dot...]))
        } else {
            (name, "")
        }
        var n = 2
        while exists("\(stem) \(n)\(ext)") { n += 1 }
        return "\(stem) \(n)\(ext)"
    }
}
