import Foundation
import MacVMModel

/// 用 curl 下载文件。服务器确实按字节范围响应 GET、文件又不小于 `segmentThreshold` 时分块并行下载：
/// 文件切成不超过 `chunkSize` 的块，始终有 `connections` 个连接从没下完的块里取，到最后也是满速。
/// 每块写进 `<目标>.seg-<起点>`（文件大小即该块进度，中断后按块续传），分块方案存在 `<目标>.segments`，
/// 续传时沿用并把剩得多的块再切开；全部下完再按顺序拼成目标文件。其余情况单连接下载：支持范围请求时接着目标文件已有的内容下，
/// 不支持时从头下。
enum Download {
    static let connections = 8
    static let chunkSize: Int64 = 256 << 20
    static let segmentThreshold: Int64 = 64 << 20

    struct Probe: Equatable {
        /// 跟随重定向后的地址。各块都请求它：镜像站的重定向每次可能指向不同镜像。
        let url: URL
        let length: Int64?
    }

    /// 返回 `target`；它不在时把 `url` 下到 `partial`，再由 `finish` 把 `partial` 做成 `target`（缺省为改名）。
    /// 整个过程持有 `partial` 的 `DownloadLock`：同一目标正由别的任务或进程在做时等它做完，做出了 `target` 就直接用。
    static func cached(_ target: URL, from url: URL, via partial: URL, showProgress: Bool,
                       finish: ((URL) async throws -> Void)? = nil) async throws -> URL {
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock: DownloadLock
        if let free = try DownloadLock(trying: partial) {
            lock = free
        } else {
            if showProgress { FileHandle.standardError.write(Data((String(l10n: "Another process is already downloading \(target.lastPathComponent); waiting for it to finish…") + "\n").utf8)) }
            lock = try await DownloadLock.acquire(partial)
        }
        defer { lock.release() }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try await file(url, to: partial, showProgress: showProgress)
        if let finish { try await finish(partial) } else { try FileManager.default.moveItem(at: partial, to: target) }
        return target
    }

    /// `file` 的 SHA-256 不等于 `expected`（十六进制，不分大小写）时删掉 `file` 并报错，`name` 用在错误信息里。
    static func verifySHA256(of file: URL, expected: String, name: String) async throws {
        let digest = try await Subprocess.run("/usr/bin/shasum", ["-a", "256", file.path])
        guard digest.split(separator: " ").first.map({ $0.lowercased() == expected.lowercased() }) == true else {
            try? FileManager.default.removeItem(at: file)
            throw MacVMError.io(String(l10n: "The SHA-256 checksum of \(name) doesn't match the published one, so the file was deleted; try again"))
        }
    }

    /// 绑定了 `DownloadProgress.handler` 时每半秒回报一次进度。调用方须持有 `destination` 的 `DownloadLock`。
    /// 探测时连不上服务器、或范围探测回了错误状态就报错，已下的内容原样留着。
    private static func file(_ url: URL, to destination: URL, showProgress: Bool) async throws {
        let probe = try await probe(url)
        // 只有要分块、或目标里已有内容要续传时才需要知道服务器认不认范围请求；没探测时为 nil。
        let ranged: Bool? = if let probe, (probe.length ?? 0) >= segmentThreshold || size(of: destination) > 0 {
            try await honorsRanges(probe.url)
        } else {
            nil
        }
        guard let probe, ranged == true, let length = probe.length, length >= segmentThreshold else {
            // 服务器明确不支持范围请求：已有内容续不上，curl 的 `-C -` 会直接报错。
            if ranged == false {
                for leftover in segmentLeftovers(of: destination) { try? FileManager.default.removeItem(at: leftover) }
                try? FileManager.default.removeItem(at: destination)
            }
            try await reportingProgress(of: [destination], total: probe?.length, toStderr: false) {
                _ = try await Subprocess.run("/usr/bin/curl", ["-fL", "--retry", "3", "-C", "-", showProgress ? "--progress-bar" : "-sS",
                                                               "-o", destination.path, url.absoluteString],
                                             passthroughStderr: showProgress)
            }
            for leftover in segmentLeftovers(of: destination) { try? FileManager.default.removeItem(at: leftover) }
            return
        }
        if size(of: destination) == length, !FileManager.default.fileExists(atPath: planURL(for: destination).path) { return }
        let ranges = try plan(for: destination, length: length)
        let files = ranges.map { segmentURL(for: destination, $0) }
        try await reportingProgress(of: files, total: length, toStderr: showProgress) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var pending = ranges[...]
                func startNext() {
                    guard let range = pending.popFirst() else { return }
                    group.addTask { try await fetch(probe.url, range: range, to: segmentURL(for: destination, range)) }
                }
                for _ in 0..<connections { startNext() }
                while try await group.next() != nil { startNext() }
            }
        }
        // 先删方案再拼接：拼到一半被打断时目标文件是从头连续的字节，下次据它重新分块。
        try FileManager.default.removeItem(at: planURL(for: destination))
        try concatenate(files, into: destination)
    }

    static func planURL(for destination: URL) -> URL { destination.appendingPathExtension("segments") }

    static func segmentURL(for destination: URL, _ range: ClosedRange<Int64>) -> URL {
        destination.appendingPathExtension("seg-\(range.lowerBound)")
    }

    /// 目标旁的块文件与方案文件。
    private static func segmentLeftovers(of destination: URL) -> [URL] {
        let prefix = destination.lastPathComponent + ".seg"
        let items = (try? FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// 读出已存的分块方案，没有时新建：目标文件里已有的从头连续的字节（单连接下了一半、或拼接到一半）改名为第一块。
    /// 然后把剩得多的块再切开，变了就存回去。
    private static func plan(for destination: URL, length: Int64) throws -> [ClosedRange<Int64>] {
        let fm = FileManager.default
        let planURL = planURL(for: destination)
        let chunk = min(chunkSize, max(1, (length + Int64(connections) - 1) / Int64(connections)))
        var ranges: [ClosedRange<Int64>]
        if let data = try? Data(contentsOf: planURL), let saved = try? JSONDecoder().decode([ClosedRange<Int64>].self, from: data),
           saved.first?.lowerBound == 0, saved.last?.upperBound == length - 1 {
            ranges = saved
            // 方案在时目标文件不属于它（如中途换成单连接下了一段），留着会让最后拼接时改名失败。
            try? fm.removeItem(at: destination)
        } else {
            for leftover in segmentLeftovers(of: destination) { try? fm.removeItem(at: leftover) }
            let prefix = size(of: destination)
            ranges = plannedRanges(length: length, prefix: prefix, chunk: chunk)
            if prefix > 0 { try fm.moveItem(at: destination, to: segmentURL(for: destination, ranges[0])) }
            try JSONEncoder().encode(ranges).write(to: planURL, options: .atomic)
        }
        let refined = refine(ranges, chunk: chunk) { size(of: segmentURL(for: destination, $0)) }
        if refined != ranges { try JSONEncoder().encode(refined).write(to: planURL, options: .atomic) }
        return refined
    }

    /// 已有前 `prefix` 字节时，它们自成第一块，其后切成不超过 `chunk` 的块。
    static func plannedRanges(length: Int64, prefix: Int64, chunk: Int64) -> [ClosedRange<Int64>] {
        let prefix = min(max(prefix, 0), length - 1)
        return (prefix > 0 ? [0...prefix - 1] : []) + chunks(prefix...length - 1, size: chunk)
    }

    /// 还剩超过两块没下的块：保留已下的部分再加一块，其余切出去，空出来的连接就能分担。
    static func refine(_ ranges: [ClosedRange<Int64>], chunk: Int64, have: (ClosedRange<Int64>) -> Int64) -> [ClosedRange<Int64>] {
        ranges.flatMap { range -> [ClosedRange<Int64>] in
            let expected = range.upperBound - range.lowerBound + 1
            let done = min(max(have(range), 0), expected)
            guard expected - done > 2 * chunk else { return [range] }
            let keepEnd = range.lowerBound + done + chunk - 1
            return [range.lowerBound...keepEnd] + chunks(keepEnd + 1...range.upperBound, size: chunk)
        }
    }

    /// 把 `range` 从头切成不超过 `size` 字节的块。
    static func chunks(_ range: ClosedRange<Int64>, size: Int64) -> [ClosedRange<Int64>] {
        Array(sequence(first: range.lowerBound) { $0 + size }.prefix { $0 <= range.upperBound }.map { $0...min($0 + size - 1, range.upperBound) })
    }

    /// 解析 `curl -sIL -w '%{url_effective}'` 的输出：只看最后一个响应的头，最后一行是最终地址。最后一个响应不是 2xx 时为 nil。
    static func parseProbe(_ output: String) -> Probe? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last, let url = URL(string: last), url.scheme != nil,
              let start = lines.lastIndex(where: { $0.hasPrefix("HTTP/") }) else { return nil }
        let status = lines[start].split(separator: " ").dropFirst().first.flatMap { Int($0) }
        guard let status, (200..<300).contains(status) else { return nil }
        var length: Int64?
        for line in lines[start...] {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" { length = Int64(parts[1]).flatMap { $0 > 0 ? $0 : nil } }
        }
        return Probe(url: url, length: length)
    }

    /// 连不上服务器时报错；服务器回了错误状态或不认 HEAD 时为 nil。
    private static func probe(_ url: URL) async throws -> Probe? {
        parseProbe(try await Subprocess.run("/usr/bin/curl", ["-sIL", "--retry", "2", "-w", "%{url_effective}", url.absoluteString]))
    }

    /// curl 的退出码：响应超过 `--max-filesize`。
    private static let curlFileTooLarge: Int32 = 63

    /// 用只要首字节的 GET 判断范围请求是否生效：HEAD 里的 `Accept-Ranges` 不可靠，有的服务器 GET 时忽略 Range、返回整个文件。
    /// 那时 `--max-filesize` 让 curl 不下正文就以 `curlFileTooLarge` 退出，`-w` 照样打出状态码。
    /// 206 为 true，其他 2xx 为 false；连不上服务器或回了非 2xx（限流、暂时不可用）时报错，不当作不支持范围请求。
    private static func honorsRanges(_ url: URL) async throws -> Bool {
        let output = try await Subprocess.run("/usr/bin/curl", ["-sL", "--retry", "2", "-r", "0-0", "--max-filesize", "1024",
                                                                "-o", "/dev/null", "-w", "%{http_code}", url.absoluteString],
                                              acceptedExitCodes: [0, curlFileTooLarge])
        let status = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = Int(status), (200..<300).contains(code) else {
            throw MacVMError.io(String(l10n: "The server returned HTTP \(status) while checking range request support (\(url.absoluteString)). The data downloaded so far was kept; try again later."))
        }
        return code == 206
    }

    /// 一段下载中途断开后，`fetch` 从段文件已有的字节接着重下的次数上限（含第一次）。
    static let fetchAttempts = 5

    /// 下载一段；段文件已有的部分不再下。curl 中途失败时（如连接被切断）按段文件的新大小重下剩余部分，至多 `fetchAttempts` 次。
    /// 服务器中途不再按范围响应时下到的字节数会对不上，报错并删掉段文件。
    private static func fetch(_ url: URL, range: ClosedRange<Int64>, to segment: URL) async throws {
        let expected = range.upperBound - range.lowerBound + 1
        if size(of: segment) > expected { try? FileManager.default.removeItem(at: segment) }
        for attempt in 1... {
            let have = size(of: segment)
            if have >= expected { break }
            if !FileManager.default.fileExists(atPath: segment.path) {
                FileManager.default.createFile(atPath: segment.path, contents: nil)
            }
            let output = try FileHandle(forWritingTo: segment)
            defer { try? output.close() }
            try output.seekToEnd()
            do {
                _ = try await Subprocess.run("/usr/bin/curl", ["-fsSL", "--retry", "5", "-r", "\(range.lowerBound + have)-\(range.upperBound)",
                                                               url.absoluteString], stdout: output)
                break
            } catch MacVMError.io where attempt < fetchAttempts {
                try await Task.sleep(for: .seconds(2))
            }
        }
        guard size(of: segment) == expected else {
            try? FileManager.default.removeItem(at: segment)
            throw MacVMError.io(String(l10n: "A segmented download got the wrong number of bytes; the server may not support range requests: \(url.absoluteString)"))
        }
    }

    /// 第一段改名为目标文件，其余按顺序追加后删掉。
    private static func concatenate(_ segments: [URL], into destination: URL) throws {
        try FileManager.default.moveItem(at: segments[0], to: destination)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        for segment in segments.dropFirst() {
            let input = try FileHandle(forReadingFrom: segment)
            while let chunk = try input.read(upToCount: 16 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try input.close()
            try FileManager.default.removeItem(at: segment)
        }
    }

    /// 运行 `body` 期间每半秒把 `files` 的大小之和报给 `DownloadProgress.handler`；`toStderr` 时同时在 stderr 打一行进度。
    private static func reportingProgress(of files: [URL], total: Int64?, toStderr: Bool, _ body: () async throws -> Void) async throws {
        let report = DownloadProgress.handler
        guard report != nil || toStderr else { return try await body() }
        let poller = Task.detached {
            while !Task.isCancelled {
                let received = files.reduce(Int64(0)) { $0 + size(of: $1) }
                report?(received, total)
                if toStderr {
                    let line = total.map { "\(ByteSize.format(UInt64(received))) / \(ByteSize.format(UInt64($0))) (\(received * 100 / max($0, 1))%)" }
                        ?? ByteSize.format(UInt64(received))
                    FileHandle.standardError.write(Data(("\r" + String(l10n: "Downloading \(line)") + "   ").utf8))
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer {
            poller.cancel()
            if toStderr { FileHandle.standardError.write(Data("\n".utf8)) }
        }
        try await body()
        if let total { report?(total, total) }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// 下载目标旁 `<目标>.lock` 上的排他锁（flock），进程退出时由系统释放。
/// 锁跟着打开的文件走，同一进程里的两个任务也互斥：两个持有者同时往同一组段文件里写会把它们写坏。
final class DownloadLock: Sendable {
    private let fd: Int32
    private let path: String

    /// 拿到锁才返回；别的持有者在用时每半秒重试一次，任务取消时抛出 `CancellationError`。
    static func acquire(_ destination: URL) async throws -> DownloadLock {
        while true {
            if let lock = try DownloadLock(trying: destination) { return lock }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// 只试一次，锁正被别的持有者占着时为 nil。
    init?(trying destination: URL) throws {
        let path = destination.appendingPathExtension("lock").path
        self.path = path
        while true {
            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw MacVMError.io(String(l10n: "Couldn't create \(path): \(String(cString: strerror(errno)))")) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            // 锁到的可能是前一个持有者 `release` 时已删掉的文件，那把锁不再排他，换新文件重来。
            var opened = stat(), current = stat()
            if fstat(fd, &opened) == 0, stat(path, &current) == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino {
                self.fd = fd
                return
            }
            close(fd)
        }
    }

    /// 持锁时删掉锁文件再解锁，不在下载目录里留下它。
    func release() {
        unlink(path)
        flock(fd, LOCK_UN)
        close(fd)
    }
}
