import Foundation
public import MacVMModel

/// 经运行虚拟机的进程（控制 socket 的 `connect`）连到客户机代理。
public enum AgentClient {
    /// 打开到代理的连接并发出请求，返回响应与连接（`exec`、`forward` 之后继续使用）。
    /// `forward` 的响应逐字节读：客户机服务可能紧跟着先说话（如 SSH 握手串），这些字节要留在 fd 里给调用方。
    static func open(_ request: AgentProtocol.Request, bundle: VMBundle, timeout: Int = 30) throws -> (AgentProtocol.Response, UnixSocket) {
        let socket = try ControlClient.openGuestPort(bundle, port: AgentProtocol.port)
        socket.setTimeout(seconds: timeout)
        let exact = if case .forward = request { true } else { false }
        guard let response = try socket.exchange(request, as: AgentProtocol.Response.self, exact: exact) else {
            throw MacVMError.io(String(l10n: "The guest agent closed the connection"))
        }
        return (response, socket)
    }

    static func call(_ request: AgentProtocol.Request, bundle: VMBundle, timeout: Int = 30) throws -> AgentProtocol.Response {
        try open(request, bundle: bundle, timeout: timeout).0.checked()
    }

    /// 发出请求，返回成功响应之后的正文（`Response.size` 字节）。
    static func fetch(_ request: AgentProtocol.Request, bundle: VMBundle, timeout: Int = 30) throws -> Data {
        let (response, socket) = try open(request, bundle: bundle, timeout: timeout)
        return try body(after: response, from: socket)
    }

    /// `response` 之后的正文；响应失败时抛出它的错误。
    static func body(after response: AgentProtocol.Response, from socket: UnixSocket) throws -> Data {
        let size = try response.checked().size ?? 0
        guard (0...AgentProtocol.maxBody).contains(size) else { throw MacVMError.io(String(l10n: "The guest agent sent a message that's too large (\(size) bytes)")) }
        guard let body = try socket.readExact(size) else { throw MacVMError.io(String(l10n: "The guest agent disconnected in the middle of a message")) }
        return body
    }

    /// 在已连到代理的 `socket` 上发一个请求，返回代理是否接受；任何失败都算不接受。
    static func call(_ request: AgentProtocol.Request, over socket: UnixSocket, timeout: Int) -> Bool {
        socket.setTimeout(seconds: timeout)
        return (try? socket.exchange(request, as: AgentProtocol.Response.self))?.ok == true
    }

    public static func info(_ bundle: VMBundle, timeout: Int = 5) throws -> AgentProtocol.Info {
        guard let info = try call(.info, bundle: bundle, timeout: timeout).info else { throw MacVMError.engine(String(l10n: "The guest agent returned no info")) }
        return info
    }

    public static func isReachable(_ bundle: VMBundle) -> Bool { (try? info(bundle, timeout: 2)) != nil }

    /// 客户机本地 TCP 端口的字节管道；返回的 socket 交给调用方转发。
    static func forward(_ bundle: VMBundle, port: UInt16) throws -> UnixSocket {
        let (response, socket) = try open(.forward(port: port), bundle: bundle)
        _ = try response.checked(String(l10n: "Couldn't forward the port"))
        socket.setTimeout(seconds: 0)
        return socket
    }

    /// 执行命令，标准输入送 `input`，返回退出码与合在一起的标准输出、标准错误。
    /// 退出码为 nil 表示没收到 `exit` 帧就断开了：命令重启了代理自己时会这样。
    static func run(_ bundle: VMBundle, request: AgentProtocol.ExecRequest, input: Data, timeout: Int = 120) throws -> (code: Int32?, output: String) {
        let (response, socket) = try open(.exec(request), bundle: bundle)
        _ = try response.checked(String(l10n: "Couldn't run the command"))
        socket.setTimeout(seconds: timeout)
        let writer = Thread {
            var offset = 0
            let chunk = AgentProtocol.maxFrame / 2
            while offset < input.count {
                let end = min(offset + chunk, input.count)
                guard (try? socket.writeAll(ExecSession.frame(.stdin, input[offset..<end]))) != nil else { return }
                offset = end
            }
            _ = try? socket.writeAll(ExecSession.frame(.stdinEOF, Data()))
        }
        writer.start()
        var output = Data()
        while true {
            guard let header = try? socket.readExact(5) else { break }
            let length = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
            guard length <= AgentProtocol.maxFrame, let payload = try? socket.readExact(length) else { break }
            switch AgentProtocol.FrameKind(rawValue: header[0]) {
            case .stdout, .stderr: output.append(payload)
            case .exit:
                let status = try JSONDecoder().decode(AgentProtocol.ExitStatus.self, from: payload)
                return (status.code, String(decoding: output, as: UTF8.self))
            default: continue
            }
        }
        return (nil, String(decoding: output, as: UTF8.self))
    }

    /// 开机后在后台等代理上线，再执行 `body`；`body` 抛错时隔一会儿重试，用完次数后把最后的错误写到标准错误。
    /// 代理在客户机登录后才启动，开机慢时要等好几分钟，等不到就什么也不做。任务取消后不再等待或重试。
    static func afterOnline(_ bundle: VMBundle, _ body: @escaping @Sendable () throws -> Void) -> Task<Void, Never> {
        Task.detached {
            var online = false
            for _ in 0..<onlineWaitAttempts {
                if Task.isCancelled { return }
                online = isReachable(bundle)
                if online { break }
                try? await Task.sleep(for: onlineWaitInterval)
            }
            guard online else { return }
            for attempt in 1...afterOnlineAttempts {
                if Task.isCancelled { return }
                do {
                    try body()
                    return
                } catch {
                    if attempt == afterOnlineAttempts {
                        FileHandle.standardError.write(Data("macvm: \((error as? MacVMError)?.message ?? "\(error)")\n".utf8))
                        return
                    }
                }
                try? await Task.sleep(for: afterOnlineRetryInterval)
            }
        }
    }

    private static let onlineWaitAttempts = 120
    private static let onlineWaitInterval: Duration = .seconds(5)
    private static let afterOnlineAttempts = 3
    private static let afterOnlineRetryInterval: Duration = .seconds(20)

    /// 执行命令，标准输入输出接到本进程，返回客户机命令的退出码。
    public static func exec(_ bundle: VMBundle, request: AgentProtocol.ExecRequest) throws -> Int32 {
        let (response, socket) = try open(.exec(request), bundle: bundle)
        _ = try response.checked(String(l10n: "Couldn't run the command"))
        socket.setTimeout(seconds: 0)
        return try ExecSession(socket: socket, tty: request.tty == true).run()
    }
}

/// exec 帧模式的宿主端：转发本进程标准输入、终端尺寸变化，输出客户机的 stdout/stderr。
final class ExecSession: @unchecked Sendable {
    private let socket: UnixSocket
    private let tty: Bool
    private let writeLock = NSLock()

    init(socket: UnixSocket, tty: Bool) {
        self.socket = socket
        self.tty = tty
    }

    func run() throws -> Int32 {
        var resizeSource: (any DispatchSourceSignal)?
        if tty {
            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
            source.setEventHandler { [weak self] in self?.sendWindowSize() }
            source.resume()
            resizeSource = source
        }
        defer { resizeSource?.cancel() }

        Thread.detachNewThread { [self] in pumpStdin() }

        while true {
            guard let header = try socket.readExact(5) else { throw MacVMError.io(String(l10n: "The guest agent disconnected unexpectedly")) }
            let length = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
            guard length <= AgentProtocol.maxFrame, let payload = try socket.readExact(length) else {
                throw MacVMError.io(String(l10n: "The guest agent sent an invalid frame"))
            }
            switch AgentProtocol.FrameKind(rawValue: header[0]) {
            case .stdout: FileHandle.standardOutput.write(payload)
            case .stderr: FileHandle.standardError.write(payload)
            case .exit:
                let status = try JSONDecoder().decode(AgentProtocol.ExitStatus.self, from: payload)
                return status.code
            default: continue
            }
        }
    }

    private func pumpStdin() {
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                send(.stdinEOF, Data())
                return
            }
            send(.stdin, Data(buf[0..<n]))
        }
    }

    private func sendWindowSize() {
        guard let size = TerminalSize.current() else { return }
        send(.resize, Data(#"{"cols":\#(size.cols),"rows":\#(size.rows)}"#.utf8))
    }

    private func send(_ kind: AgentProtocol.FrameKind, _ payload: Data) {
        let frame = Self.frame(kind, payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try? socket.writeAll(frame)
    }

    static func frame(_ kind: AgentProtocol.FrameKind, _ payload: Data) -> Data {
        frame(kind.rawValue, payload)
    }

    static func frame(_ kind: UInt8, _ payload: some DataProtocol) -> Data {
        var frame = Data([kind])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: payload)
        return frame
    }
}

public enum TerminalSize {
    public static func current() -> (cols: Int, rows: Int)? {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 || ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
}
