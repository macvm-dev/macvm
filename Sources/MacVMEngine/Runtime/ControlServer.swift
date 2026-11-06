import Foundation
public import MacVMModel

/// 在运行虚拟机的进程里监听控制 socket，把请求交给 `MachineRunner`。
public final class ControlServer: @unchecked Sendable {
    private let socket: UnixSocket
    private let path: String
    private let runner: any MachineRunner
    private let inode: ino_t
    /// 管道两端：`close` 往写端写，接收线程据此退出，线程放开对本对象的引用后监听 fd 随之关闭。
    private let wake: (read: Int32, write: Int32)

    @MainActor
    public init(runner: any MachineRunner) throws {
        try RuntimeDirectory.ensure()
        path = runner.bundle.controlSocketURL.path
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw MacVMError.posix("pipe") }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        do {
            socket = try UnixSocket.listen(at: path)
        } catch {
            for end in ends { Darwin.close(end) }
            throw error
        }
        wake = (ends[0], ends[1])
        var st = stat()
        inode = stat(path, &st) == 0 ? st.st_ino : 0
        self.runner = runner
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "macvm.control"
        thread.start()
    }

    deinit {
        Darwin.close(wake.read)
        Darwin.close(wake.write)
    }

    /// 停止接收新请求，已建立的连接不受影响。只删除仍是本进程创建的 socket 文件，不误删新进程刚建的同名 socket。
    public func close() {
        var st = stat()
        if stat(path, &st) == 0, st.st_ino == inode { unlink(path) }
        var byte: UInt8 = 0
        _ = Darwin.write(wake.write, &byte, 1)
    }

    private func acceptLoop() {
        while let client = socket.accept(cancel: wake.read) {
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
            response = ControlResponse(failure: error)
        } catch {
            response = ControlResponse(ok: false, errorCode: "bad_request", message: "\(error)")
        }
        reply(response, to: client)
    }

    @discardableResult
    private static func reply(_ response: ControlResponse, to client: UnixSocket) -> Bool {
        guard let data = try? JSONEncoder().encode(response) else { return false }
        return (try? client.writeLine(data)) != nil
    }

    /// 成功时先回 ok，再在专用线程上双向转发，直到任一方关闭。
    private static func bridge(_ client: UnixSocket, toGuestPort port: UInt32, runner: any MachineRunner) async {
        let channel: GuestChannel
        do {
            channel = try await runner.openGuestChannel(port: port)
        } catch {
            reply(ControlResponse(failure: error), to: client)
            return
        }
        guard reply(ControlResponse(ok: true), to: client) else {
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
        } catch {
            return ControlResponse(failure: error, state: runner.stateLabel)
        }
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, to bundle: VMBundle, timeout: Int = 60) throws -> ControlResponse {
        try exchange(request, over: connect(bundle, timeout: timeout), exact: false)
    }

    /// 发出请求，失败的响应转成对应的 `MacVMError` 抛出。
    public static func perform(_ request: ControlRequest, on bundle: VMBundle, timeout: Int = 60) throws {
        if let error = try send(request, to: bundle, timeout: timeout).failure { throw error }
    }

    /// 经运行虚拟机的进程连到客户机端口，返回已切换为字节管道的连接。
    static func openGuestPort(_ bundle: VMBundle, port: UInt32) throws -> UnixSocket {
        let socket = try connect(bundle, timeout: 30)
        // 逐字节读：客户机服务可能紧跟着先说话，这些字节要留在 fd 里给调用方。
        let response = try exchange(.connect(port: port), over: socket, exact: true)
        if let error = response.failure { throw error }
        socket.setTimeout(seconds: 0)
        return socket
    }

    private static func connect(_ bundle: VMBundle, timeout: Int) throws -> UnixSocket {
        guard BundleLock.holder(of: bundle) != nil else { throw MacVMError.notRunning(bundle.name) }
        let socket: UnixSocket
        do { socket = try UnixSocket.connect(to: bundle.controlSocketURL.path) } catch { throw MacVMError.notRunning(bundle.name) }
        socket.setTimeout(seconds: timeout)
        return socket
    }

    private static func exchange(_ request: ControlRequest, over socket: UnixSocket, exact: Bool) throws -> ControlResponse {
        guard let response = try socket.exchange(request, as: ControlResponse.self, exact: exact) else {
            throw MacVMError.io(String(l10n: "The control connection was closed"))
        }
        return response
    }
}
