public import Foundation
public import MacVMModel

/// 经运行虚拟机的进程（控制 socket 的 `connect`）连到客户机代理。
public enum AgentClient {
    /// 打开到代理的连接并发出请求，返回响应与连接（`exec`、`forward` 之后继续使用）。
    /// `forward` 的响应逐字节读：客户机服务可能紧跟着先说话（如 SSH 握手串），这些字节要留在 fd 里给调用方。
    static func open(_ request: AgentProtocol.Request, bundle: VMBundle, timeout: Int = 30) throws -> (AgentProtocol.Response, UnixSocket) {
        let socket = try ControlClient.openGuestPort(bundle, port: AgentProtocol.port)
        socket.setTimeout(seconds: timeout)

        try socket.writeLine(JSONEncoder().encode(request))
        let exact = if case .forward = request { true } else { false }
        guard let line = try socket.readLine(exact: exact) else { throw MacVMError.io("客户机代理关闭了连接") }
        let response = try JSONDecoder().decode(AgentProtocol.Response.self, from: line)
        return (response, socket)
    }

    static func call(_ request: AgentProtocol.Request, bundle: VMBundle, timeout: Int = 30) throws -> AgentProtocol.Response {
        let (response, _) = try open(request, bundle: bundle, timeout: timeout)
        guard response.ok else { throw MacVMError.engine("客户机代理：\(response.error ?? "未知错误")") }
        return response
    }

    public static func info(_ bundle: VMBundle, timeout: Int = 5) throws -> AgentProtocol.Info {
        guard let info = try call(.info, bundle: bundle, timeout: timeout).info else { throw MacVMError.engine("客户机代理未返回信息") }
        return info
    }

    public static func isReachable(_ bundle: VMBundle) -> Bool { (try? info(bundle, timeout: 2)) != nil }

    public static func shutdown(_ bundle: VMBundle, reboot: Bool = false) throws { _ = try call(.shutdown(reboot: reboot), bundle: bundle) }
    public static func setTime(_ bundle: VMBundle, to date: Date = Date()) throws { _ = try call(.setTime(unixMs: Int64(date.timeIntervalSince1970 * 1000)), bundle: bundle) }
    public static func clipboard(_ bundle: VMBundle) throws -> String { try call(.clipboardGet, bundle: bundle).text ?? "" }
    public static func setClipboard(_ bundle: VMBundle, text: String) throws { _ = try call(.clipboardSet(text: text), bundle: bundle) }

    /// 客户机本地 TCP 端口的字节管道；返回的 socket 交给调用方转发。
    static func forward(_ bundle: VMBundle, port: UInt16) throws -> UnixSocket {
        let (response, socket) = try open(.forward(port: port), bundle: bundle)
        guard response.ok else { throw MacVMError.engine("客户机代理：\(response.error ?? "端口转发失败")") }
        socket.setTimeout(seconds: 0)
        return socket
    }

    /// 执行命令，标准输入输出接到本进程，返回客户机命令的退出码。
    public static func exec(_ bundle: VMBundle, request: AgentProtocol.ExecRequest) throws -> Int32 {
        let (response, socket) = try open(.exec(request), bundle: bundle)
        guard response.ok else { throw MacVMError.engine("客户机代理：\(response.error ?? "执行失败")") }
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
            guard let header = try socket.readExact(5) else { throw MacVMError.io("客户机代理意外断开") }
            let length = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
            guard length <= AgentProtocol.maxFrame, let payload = try socket.readExact(length) else {
                throw MacVMError.io("客户机代理发来无效帧")
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
        var frame = Data([kind.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try? socket.writeAll(frame)
    }
}

public enum TerminalSize {
    public static func current() -> (cols: Int, rows: Int)? {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 || ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
}
