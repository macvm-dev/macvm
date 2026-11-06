public import Foundation
public import MacVMModel

/// 连到客户机内的 TCP 端口。
public enum GuestConnection {
    /// 返回连到客户机 `port` 的文件描述符，调用方负责关闭：
    /// QEMU 引擎经其转发到 Unix socket 的端口；装有代理时经代理转发；否则经网络直连客户机 IP。
    public static func open(_ bundle: VMBundle, config: VMConfig, port: UInt16, timeout: TimeInterval = 60) async throws -> Int32 {
        if config.engine == .qemu || config.guestAgent {
            let socket = config.engine == .qemu
                ? try ControlClient.openGuestPort(bundle, port: UInt32(port))
                : try AgentClient.forward(bundle, port: port)
            return try socket.duplicateDescriptor()
        }
        return try await connect(to: bundle, port: port, timeout: timeout)
    }

    public static func connect(to bundle: VMBundle, port: UInt16, timeout: TimeInterval = 60) async throws -> Int32 {
        guard BundleLock.holder(of: bundle) != nil else { throw MacVMError.notRunning(bundle.name) }
        guard let ip = try await VMStatus.waitForIPAddress(bundle, timeout: timeout, interval: 0.5) else { throw MacVMError.timeout(String(l10n: "Couldn't find \(bundle.name)'s IP address")) }

        var fd: Int32 = -1
        var target = ip
        let deadline = Date().addingTimeInterval(timeout)
        _ = try await VMStatus.poll(timeout: timeout, interval: 0.5) {
            // 客户机开机后可能换了地址，每次重试都重新取。
            target = (try? VMStatus.summary(of: bundle).ipAddress) ?? target
            fd = tcpConnect(target, port, timeout: min(connectTimeout, max(deadline.timeIntervalSinceNow, 0.1)))
            return fd >= 0
        }
        guard fd >= 0 else { throw MacVMError.timeout(String(l10n: "Timed out connecting to \(target):\(port)")) }
        return fd
    }

    /// 经网络直连客户机 `ip` 上的 `port`。连的是代理端口时先过 `AgentToken.authenticate`。
    static func direct(_ ip: String, port: UInt16, bundle: VMBundle, config: VMConfig) throws -> UnixSocket {
        let fd = tcpConnect(ip, port)
        guard fd >= 0 else { throw MacVMError.posix(String(l10n: "Couldn't connect to \(ip):\(port)")) }
        let socket = UnixSocket(fd: fd)
        if UInt32(port) == AgentProtocol.port {
            try AgentToken.authenticate(socket, bundle: bundle, bridged: config.networks.first?.mode == .bridged)
        }
        return socket
    }

    /// 单次 TCP 连接最多等多久；客户机不回应时不必等到系统的 SYN 超时。
    static let connectTimeout: TimeInterval = 5

    /// 连不上或 `timeout` 内没连上时返回 -1，`errno` 是原因。
    static func tcpConnect(_ ip: String, _ port: UInt16, timeout: TimeInterval = GuestConnection.connectTimeout) -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { errno = EINVAL; return -1 }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0, errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pfd, 1, Int32(max(timeout, 0) * 1000))
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if ready == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 {
                if error == 0 { rc = 0 } else { errno = error }
            } else if ready == 0 {
                errno = ETIMEDOUT
            }
        }
        if rc != 0 {
            let reason = errno
            close(fd)
            errno = reason
            return -1
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// 在 `a` 与 `b` 之间双向转发。`a` 的输入结束时半关闭 `b` 的写端并继续回传；
    /// `b` 的输出结束（对端关闭）后返回，调用方随即可以关闭 `a` 与 `b`。
    public static func pump(_ a: (read: Int32, write: Int32), _ b: Int32) {
        // 另一方向的线程可能晚于本函数结束，它用自己复制的描述符：调用方关掉原来的之后，
        // 同号的 fd 可能已分给别的连接。
        let input = dup(a.read), output = dup(b)
        guard input >= 0, output >= 0 else {
            if input >= 0 { close(input) }
            if output >= 0 { close(output) }
            return
        }
        var on: Int32 = 1
        setsockopt(output, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread {
            copy(from: input, to: output)
            shutdown(output, SHUT_WR)
            close(input)
            close(output)
        }
        copy(from: b, to: a.write)
        // 会话已结束：唤醒仍阻塞在读 `a` 或写 `b` 上的那个线程，它手里的副本才会及时关掉。
        shutdown(b, SHUT_WR)
        shutdown(a.read, SHUT_RD)
    }

    private static func copy(from: Int32, to: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(from, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                if w < 0, errno == EINTR { continue }
                if w <= 0 { return }
                off += w
            }
        }
    }
}
