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
        guard let ip = try await VMStatus.waitForIPAddress(bundle, timeout: timeout, interval: 0.5) else { throw MacVMError.timeout("未找到 \(bundle.name) 的 IP 地址") }

        var fd: Int32 = -1
        _ = try await VMStatus.poll(timeout: timeout, interval: 0.5) {
            fd = tcpConnect(ip, port)
            return fd >= 0
        }
        guard fd >= 0 else { throw MacVMError.timeout("连接 \(ip):\(port) 超时") }
        return fd
    }

    /// 经网络直连客户机 `ip` 上的 `port`。桥接网络下宿主不是客户机的默认网关，连代理端口要先过 `AgentToken.authenticate`。
    static func direct(_ ip: String, port: UInt16, bundle: VMBundle, config: VMConfig) throws -> UnixSocket {
        let fd = tcpConnect(ip, port)
        guard fd >= 0 else { throw MacVMError.posix("连接 \(ip):\(port)") }
        let socket = UnixSocket(fd: fd)
        if UInt32(port) == AgentProtocol.port, config.networks.first?.mode == .bridged {
            try AgentToken.authenticate(socket, bundle: bundle)
        }
        return socket
    }

    static func tcpConnect(_ ip: String, _ port: UInt16) -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return -1 }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
    }

    /// 在 `a` 与 `b` 之间双向转发。`a` 的输入结束时半关闭 `b` 的写端并继续回传；
    /// `b` 的输出结束（对端关闭）后返回。
    public static func pump(_ a: (read: Int32, write: Int32), _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            copy(from: a.read, to: b)
            shutdown(b, SHUT_WR)
        }
        Thread.detachNewThread {
            copy(from: b, to: a.write)
            done.signal()
        }
        done.wait()
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
