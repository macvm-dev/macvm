public import Foundation
public import MacVMModel

/// 在运行虚拟机的进程里监听控制 socket，把请求交给 `MachineRunner`。
public final class ControlServer: @unchecked Sendable {
    private let socket: UnixSocket
    private let path: String
    private let runner: any MachineRunner
    private let inode: ino_t

    @MainActor
    public init(runner: any MachineRunner) throws {
        try RuntimeDirectory.ensure()
        path = runner.bundle.controlSocketURL.path
        socket = try UnixSocket.listen(at: path)
        var st = stat()
        inode = stat(path, &st) == 0 ? st.st_ino : 0
        self.runner = runner
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "macvm.control"
        thread.start()
    }

    /// 只删除仍是本进程创建的 socket 文件，不误删新进程刚建的同名 socket。
    public func close() {
        var st = stat()
        if stat(path, &st) == 0, st.st_ino == inode { unlink(path) }
    }

    private func acceptLoop() {
        while let client = socket.accept() {
            Task.detached { [runner] in await Self.serve(client, runner: runner) }
        }
    }

    private static func serve(_ client: UnixSocket, runner: any MachineRunner) async {
        client.setTimeout(seconds: 30)
        let response: ControlResponse
        do {
            guard let line = try client.readLine() else { return }
            let request = try JSONDecoder().decode(ControlRequest.self, from: line)
            if case .connect(let port) = request {
                await bridge(client, toGuestPort: port, runner: runner)
                return
            }
            response = await handle(request, runner: runner)
        } catch let error as MacVMError {
            response = ControlResponse(ok: false, errorCode: error.code, message: error.message)
        } catch {
            response = ControlResponse(ok: false, errorCode: "bad_request", message: "\(error)")
        }
        if let data = try? JSONEncoder().encode(response) { try? client.writeLine(data) }
    }

    /// 成功时先回 ok，再在专用线程上双向转发，直到任一方关闭。
    private static func bridge(_ client: UnixSocket, toGuestPort port: UInt32, runner: any MachineRunner) async {
        let channel: GuestChannel
        do {
            channel = try await runner.openGuestChannel(port: port)
        } catch {
            let e = error as? MacVMError ?? .engine(error.localizedDescription)
            if let data = try? JSONEncoder().encode(ControlResponse(ok: false, errorCode: e.code, message: e.message)) { try? client.writeLine(data) }
            return
        }
        guard let data = try? JSONEncoder().encode(ControlResponse(ok: true)), (try? client.writeLine(data)) != nil else {
            channel.close()
            return
        }
        client.setTimeout(seconds: 0)
        let leftover = client.takeBuffered()
        let thread = Thread {
            let guest = channel.fileDescriptor
            if !leftover.isEmpty {
                _ = leftover.withUnsafeBytes { write(guest, $0.baseAddress!, $0.count) }
            }
            GuestConnection.pump((client.fd, client.fd), guest)
            channel.close()
        }
        thread.name = "macvm.bridge.\(port)"
        thread.start()
    }

    @MainActor
    private static func handle(_ request: ControlRequest, runner: any MachineRunner) async -> ControlResponse {
        do {
            switch request {
            case .status, .connect: break
            case .stop(force: false): try runner.requestStop()
            case .stop(force: true): try await runner.forceStop()
            case .suspend: try await runner.suspend()
            case .pause: try await runner.pause()
            case .resume: try await runner.resume()
            case .screenshot(let path): try await runner.screenshot(to: URL(filePath: path))
            case .display(let width, let height): try runner.resizeDisplay(width: width, height: height)
            }
            return ControlResponse(ok: true, state: runner.stateLabel, pid: getpid(), canSuspend: runner.canSuspend)
        } catch let error as MacVMError {
            return ControlResponse(ok: false, state: runner.stateLabel, errorCode: error.code, message: error.message)
        } catch {
            return ControlResponse(ok: false, state: runner.stateLabel, errorCode: MacVMError.engine("").code, message: error.localizedDescription)
        }
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, to bundle: VMBundle, timeout: Int = 60) throws -> ControlResponse {
        guard BundleLock.holder(of: bundle) != nil else { throw MacVMError.notRunning(bundle.name) }
        let socket: UnixSocket
        do { socket = try UnixSocket.connect(to: bundle.controlSocketURL.path) } catch {
            throw MacVMError.notRunning(bundle.name)
        }
        socket.setTimeout(seconds: timeout)
        try socket.writeLine(try JSONEncoder().encode(request))
        guard let line = try socket.readLine() else {
            throw MacVMError.io("控制连接被关闭")
        }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }

    /// 经运行虚拟机的进程连到客户机端口，返回已切换为字节管道的连接。
    static func openGuestPort(_ bundle: VMBundle, port: UInt32) throws -> UnixSocket {
        guard BundleLock.holder(of: bundle) != nil else { throw MacVMError.notRunning(bundle.name) }
        let socket: UnixSocket
        do { socket = try UnixSocket.connect(to: bundle.controlSocketURL.path) } catch { throw MacVMError.notRunning(bundle.name) }
        socket.setTimeout(seconds: 30)
        try socket.writeLine(JSONEncoder().encode(ControlRequest.connect(port: port)))
        // 逐字节读：客户机服务可能紧跟着先说话，这些字节要留在 fd 里给调用方。
        guard let line = try socket.readLine(exact: true) else { throw MacVMError.io("控制连接被关闭") }
        let response = try JSONDecoder().decode(ControlResponse.self, from: line)
        guard response.ok else { throw MacVMError.notRunning(response.message ?? "客户机端口 \(port) 不可达") }
        socket.setTimeout(seconds: 0)
        return socket
    }

    /// 把失败的响应转成对应的 `MacVMError`。
    public static func check(_ response: ControlResponse, bundle: VMBundle) throws -> ControlResponse {
        guard !response.ok else { return response }
        let message = response.message ?? "未知错误"
        switch response.errorCode {
        case "not_running": throw MacVMError.notRunning(bundle.name)
        case "unsupported": throw MacVMError.unsupported(message)
        default: throw MacVMError.engine(message)
        }
    }
}
