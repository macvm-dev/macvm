import Foundation
public import MacVMModel

/// 在宿主上监听 `PortForward`，把连进来的 TCP 连接接到客户机端口。每个监听一条接收线程，每个连接一条转发线程。
public final class PortForwarder: @unchecked Sendable {
    /// 连到客户机端口，返回 fd 交给转发；阻塞，在转发线程上调用。
    typealias Dial = @Sendable (UInt16) throws -> Int32

    private let dial: Dial
    private let onError: @Sendable (PortForward, any Error) -> Void
    private let lock = NSLock()
    private var listeners: [PortForward: Listener] = [:]

    /// `onError` 收到单个连接接不到客户机的原因，在转发线程上调用。
    public convenience init(bundle: VMBundle, onError: @escaping @Sendable (PortForward, any Error) -> Void = { _, _ in }) {
        self.init(dial: { try GuestConnection.openForward(bundle, port: $0) }, onError: onError)
    }

    init(dial: @escaping Dial, onError: @escaping @Sendable (PortForward, any Error) -> Void) {
        self.dial = dial
        self.onError = onError
    }

    deinit { close() }

    public var active: [PortForward] {
        lock.withLock { Array(listeners.keys) }
    }

    /// 让监听与 `forwards` 一致：先停掉不再需要的（已建立的连接不断开），再监听新增的，
    /// 同一宿主端口换了客户机端口时不会撞上自己。返回监听失败的各项。
    @discardableResult
    public func apply(_ forwards: [PortForward]) -> [(PortForward, MacVMError)] {
        lock.withLock {
            let wanted = Set(forwards)
            for (forward, listener) in listeners where !wanted.contains(forward) {
                listener.close()
                listeners[forward] = nil
            }
            var failures: [(PortForward, MacVMError)] = []
            for forward in forwards where listeners[forward] == nil {
                do {
                    listeners[forward] = try Listener(forward: forward, dial: dial, onError: onError)
                } catch {
                    failures.append((forward, error as? MacVMError ?? .engine(error.localizedDescription)))
                }
            }
            return failures
        }
    }

    /// 停掉全部监听，已建立的连接不断开。可重复调用。
    public func close() {
        lock.withLock {
            listeners.values.forEach { $0.close() }
            listeners.removeAll()
        }
    }

    /// 监听失败合成一条错误；没有失败时为 nil。
    public static func combined(_ failures: [(PortForward, MacVMError)]) -> MacVMError? {
        guard !failures.isEmpty else { return nil }
        if failures.count == 1 { return failures[0].1 }
        return .io(failures.map(\.1.message).joined(separator: "\n"))
    }
}

/// 一个监听 socket 与它的接收线程。
private final class Listener: @unchecked Sendable {
    private let wake: (read: Int32, write: Int32)
    private let finished = DispatchSemaphore(value: 0)

    init(forward: PortForward, dial: @escaping PortForwarder.Dial, onError: @escaping @Sendable (PortForward, any Error) -> Void) throws {
        let fd = try Self.listen(forward)
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            Darwin.close(fd)
            throw MacVMError.posix("pipe")
        }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        wake = (ends[0], ends[1])
        let cancel = wake.read, finished = finished
        let thread = Thread {
            while let client = Self.accept(fd, cancel: cancel) {
                let worker = Thread {
                    defer { Darwin.close(client) }
                    let guest: Int32
                    do { guest = try dial(forward.guestPort) } catch {
                        Self.reset(client)
                        onError(forward, error)
                        return
                    }
                    GuestConnection.pump((client, client), guest)
                    Darwin.close(guest)
                }
                worker.name = "macvm.forward.\(forward.hostPort)"
                worker.start()
            }
            Darwin.close(fd)
            finished.signal()
        }
        thread.name = "macvm.forward.listen.\(forward.hostPort)"
        thread.start()
    }

    deinit {
        Darwin.close(wake.read)
        Darwin.close(wake.write)
    }

    /// 等接收线程退出、监听 fd 关掉才返回：随后在同一端口重新监听不会报占用。
    func close() {
        var byte: UInt8 = 0
        _ = Darwin.write(wake.write, &byte, 1)
        finished.wait()
        finished.signal()
    }

    /// 先不带 `SO_REUSEADDR` 绑定：带上它时 BSD 不把通配地址与具体地址算作冲突，会抢走别的程序在同一端口上的本机流量。
    /// 占用只来自本端口残留的连接（没有监听者）时才带上它重绑。
    private static func listen(_ forward: PortForward) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = forward.hostPort.bigEndian
        guard inet_pton(AF_INET, forward.address, &addr.sin_addr) == 1 else {
            throw MacVMError.invalidConfig(String(l10n: "Not an IPv4 address: \(forward.address)"))
        }
        var result = try bindAndListen(addr, reuse: false)
        if case .failure(EADDRINUSE) = result, !hasListener(forward) {
            result = try bindAndListen(addr, reuse: true)
        }
        switch result {
        case .success(let fd):
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            return fd
        case .failure(EADDRINUSE):
            throw MacVMError.io(String(l10n: "Couldn't listen on \(forward.address):\(String(forward.hostPort)): the port is already in use"))
        case .failure(let code):
            throw MacVMError.posix(String(l10n: "Couldn't listen on \(forward.address):\(String(forward.hostPort))"), code: code)
        }
    }

    private enum Bound { case success(Int32), failure(Int32) }

    private static func bindAndListen(_ addr: sockaddr_in, reuse: Bool) throws -> Bound {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacVMError.posix("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if reuse {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = addr
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            return .failure(code)
        }
        return .success(fd)
    }

    /// 本机能否连上这个端口；通配地址从回环探测。
    private static func hasListener(_ forward: PortForward) -> Bool {
        let host = forward.address == PortForward.anyAddress ? "127.0.0.1" : forward.address
        let fd = GuestConnection.tcpConnect(host, forward.hostPort)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    /// 等下一个连接，返回阻塞式的 fd；`cancel` 可读或监听 fd 失效时返回 nil。
    private static func accept(_ fd: Int32, cancel: Int32) -> Int32? {
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: cancel, events: Int16(POLLIN), revents: 0)]
        while true {
            if poll(&fds, nfds_t(fds.count), -1) < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if fds[1].revents != 0 { return nil }
            guard fds[0].revents & Int16(POLLIN) != 0 else { return nil }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, EAGAIN, ECONNABORTED: continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    usleep(100_000)
                    continue
                default: return nil
                }
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            return client
        }
    }

    /// 关闭时发 RST：客户端看到连接被拒，而不是连上后立即读到结束。
    private static func reset(_ fd: Int32) {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
    }
}
