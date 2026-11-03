import Foundation
import MacVMModel

/// 阻塞式 Unix 域流 socket 的最小封装。
final class UnixSocket: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    static func listen(at path: String) throws -> UnixSocket {
        unlink(path)
        let socket = try make()
        try withAddress(path) { addr, len in
            guard bind(socket.fd, addr, len) == 0 else { throw MacVMError.posix("bind \(path)") }
        }
        chmod(path, 0o600)
        guard Darwin.listen(socket.fd, 16) == 0 else { throw MacVMError.posix("listen \(path)") }
        return socket
    }

    static func connect(to path: String) throws -> UnixSocket {
        let socket = try make()
        try withAddress(path) { addr, len in
            guard Darwin.connect(socket.fd, addr, len) == 0 else { throw MacVMError.posix("connect \(path)") }
        }
        return socket
    }

    func accept() -> UnixSocket? {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        Self.disableSigpipe(client)
        return UnixSocket(fd: client)
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MacVMError.posix("write")
                }
                offset += n
            }
        }
    }

    func writeLine(_ data: Data) throws {
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    /// 读到换行为止（不含换行）；对端关闭且没有剩余数据时返回 nil。
    /// `exact` 时逐字节读，不越过换行，之后的字节留在 fd 里，供把 fd 交给别人直接转发的调用方用。
    func readLine(limit: Int = 1 << 20, exact: Bool = false) throws -> Data? {
        var scanned = buffer.startIndex
        var chunk = [UInt8](repeating: 0, count: exact ? 1 : 4096)
        while true {
            if let nl = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            scanned = buffer.endIndex
            guard buffer.count < limit else { throw MacVMError.io("控制消息超长") }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw MacVMError.posix("read")
            }
            if n == 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// 读满 `count` 字节，先取 `readLine` 缓冲中剩余的数据；对端提前关闭时返回 nil。
    func readExact(_ count: Int) throws -> Data? {
        var out = Data(count: count)
        let complete = try out.withUnsafeMutableBytes { try readExact(into: $0) }
        return complete ? out : nil
    }

    /// 读满 `destination`，先取 `readLine` 缓冲中剩余的数据；对端提前关闭时返回 false。
    func readExact(into destination: UnsafeMutableRawBufferPointer) throws -> Bool {
        let buffered = min(buffer.count, destination.count)
        if buffered > 0 {
            buffer.copyBytes(to: destination.bindMemory(to: UInt8.self), from: buffer.startIndex..<buffer.startIndex + buffered)
            buffer.removeFirst(buffered)
        }
        var filled = buffered
        while filled < destination.count {
            let n = Darwin.read(fd, destination.baseAddress! + filled, destination.count - filled)
            if n < 0 {
                if errno == EINTR { continue }
                throw MacVMError.posix("read")
            }
            if n == 0 { return false }
            filled += n
        }
        return true
    }

    /// 发一行 JSON 请求、读一行 JSON 响应；对端不回话就关闭时返回 nil。
    /// `exact` 时不越过响应行读取，响应之后对端发来的字节留在 fd 里。
    func exchange<Response: Decodable>(_ request: some Encodable, as: Response.Type, exact: Bool = false) throws -> Response? {
        try writeLine(JSONEncoder().encode(request))
        guard let line = try readLine(exact: exact) else { return nil }
        return try JSONDecoder().decode(Response.self, from: line)
    }

    /// 复制出一个独立的 fd 交给调用方关闭；本对象析构时只关闭自己的那个。
    func duplicateDescriptor() throws -> Int32 {
        let copy = dup(fd)
        guard copy >= 0 else { throw MacVMError.posix("复制连接") }
        return copy
    }

    /// 取出 `readLine` 之后缓冲里尚未消费的字节，转交给原始字节转发。
    func takeBuffered() -> Data {
        defer { buffer.removeAll() }
        return buffer
    }

    func setTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func make() throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacVMError.posix("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        disableSigpipe(fd)
        return UnixSocket(fd: fd)
    }

    private static func disableSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw MacVMError.io("socket 路径过长：\(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

}
