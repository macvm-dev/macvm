public import Foundation
public import MacVMModel

/// 以 QEMU（hvf 加速）子进程运行虚拟机，经 QMP 控制。
@MainActor
public final class QEMURunner: MachineRunner {
    public let bundle: VMBundle
    public let config: VMConfig
    public private(set) var stateLabel = "stopped"
    public var onStop: ((MachineStopReason) -> Void)?

    private let qemu: QEMUInstallation
    private let lock: BundleLock
    private let display: Bool
    private var process: Process?
    private var qmp: QMPClient?
    private var stopReason: MachineStopReason?
    private var stopWaiters: [CheckedContinuation<MachineStopReason, Never>] = []

    /// `display` 为 true 时由 QEMU 自己开一个 Cocoa 窗口显示画面。
    public init(bundle: VMBundle, display: Bool = false) throws {
        qemu = try QEMUInstallation.require()
        lock = try BundleLock.acquire(bundle)
        self.bundle = bundle
        self.display = display
        config = try bundle.loadConfig()
        try qemu.ensureVars(for: bundle)
        _ = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments()
    }

    public var canSuspend: Bool { config.supportsSuspend }

    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        try RuntimeDirectory.ensure()
        if bundle.hasSavedState, !recovery {
            do {
                try await launch(incoming: bundle.savedStateURL)
                try await waitForMigration()
                try await qmp?.execute("cont")
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                stateLabel = "running"
                return .restored
            } catch {
                await terminate()
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                try await launch(incoming: nil)
                stateLabel = "running"
                pressKeysForInstallMedia()
                return .restoreFailed(VZRunner.describe(error))
            }
        }
        try await launch(incoming: nil)
        stateLabel = "running"
        pressKeysForInstallMedia()
        return .coldBoot
    }

    public func requestStop() throws {
        guard let qmp, process?.isRunning == true else { throw MacVMError.notRunning(bundle.name) }
        Task { _ = try? await qmp.execute("system_powerdown") }
    }

    public func forceStop() async throws {
        guard process?.isRunning == true else { throw MacVMError.notRunning(bundle.name) }
        await terminate()
        finish(.forced)
    }

    public func pause() async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try await qmp.execute("stop")
        stateLabel = "paused"
    }

    public func resume() async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try await qmp.execute("cont")
        stateLabel = "running"
    }

    /// 暂停后把内存与设备状态迁移到包内文件，然后退出 QEMU；下次 `start` 以 `-incoming` 读回。
    public func suspend() async throws {
        guard canSuspend else { throw MacVMError.unsupported("该虚拟机的配置不支持挂起") }
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try await qmp.execute("stop")
        stateLabel = "saving"
        do {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            try await qmp.execute("migrate", ["uri": "file:\(bundle.savedStateURL.path)"])
            try await waitForMigration()
        } catch {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            _ = try? await qmp.execute("cont")
            stateLabel = "running"
            throw error
        }
        await terminate()
        finish(.suspended)
    }

    public func waitUntilStopped() async -> MachineStopReason {
        if let stopReason { return stopReason }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    public func screenshot(to url: URL) async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try await qmp.execute("screendump", ["filename": url.path, "format": "png"])
    }

    public func resizeDisplay(width: Int, height: Int) throws {
        throw MacVMError.unsupported("QEMU 引擎不支持运行中调整显示尺寸")
    }

    /// 只有 `QEMUCommand.forwardedPorts` 中的端口可达。
    public func openGuestChannel(port: UInt32) async throws -> GuestChannel {
        guard QEMUCommand.forwardedPorts.contains(port) else {
            throw MacVMError.unsupported("QEMU 引擎只转发客户机端口 \(QEMUCommand.forwardedPorts.map(String.init).joined(separator: "、"))")
        }
        let socket = try UnixSocket.connect(to: QEMUCommand.portSocket(bundle, port: port).path)
        // socket 析构时关闭 fd，要在它存活期间复制。
        let fd = withExtendedLifetime(socket) { dup(socket.fd) }
        guard fd >= 0 else { throw MacVMError.io("复制连接失败：\(String(cString: strerror(errno)))") }
        return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
    }

    // MARK: - 进程

    private func launch(incoming: URL?) async throws {
        let qmpPath = QEMUCommand.qmpSocket(bundle).path
        // 能连上说明上一个 QEMU 还在运行（持有锁的进程已不在）；删掉它的 socket 会让它再也无法管理。
        if (try? UnixSocket.connect(to: qmpPath)) != nil {
            throw MacVMError.engine("\(bundle.name) 上次的 QEMU 进程仍在运行，先结束它（ps 中 -name \(bundle.name) 的 qemu-system-aarch64）")
        }
        for path in [QEMUCommand.qmpSocket(bundle)] + QEMUCommand.forwardedPorts.map({ QEMUCommand.portSocket(bundle, port: $0) }) {
            unlink(path.path)
        }
        var command = QEMUCommand(bundle: bundle, config: config, qemu: qemu)
        command.display = display
        command.incoming = incoming

        let process = Process()
        process.executableURL = qemu.binary
        process.arguments = try command.arguments()
        process.standardInput = FileHandle.nullDevice
        let stderr = StderrTail()
        process.standardError = stderr.pipe
        let token = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.processExited(token, status: status) }
        }
        do { try process.run() } catch {
            throw MacVMError.engine("无法启动 QEMU：\(error.localizedDescription)")
        }
        self.process = process
        stateLabel = "starting"

        let client: QMPClient
        do {
            client = try await QMPClient.connect(to: qmpPath, timeout: 15) { [process = Unchecked(value: process)] in process.value.isRunning }
        } catch {
            let detail = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw detail.isEmpty ? error : MacVMError.engine("QEMU 启动失败：\(detail)")
        }
        client.onEvent = { [weak self] event, _ in
            Task { @MainActor in self?.handle(event: event) }
        }
        qmp = client
    }

    private func handle(event: String) {
        switch event {
        case "STOP": if stateLabel == "running" { stateLabel = "paused" }
        case "RESUME": stateLabel = "running"
        default: break
        }
    }

    private func waitForMigration() async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        while true {
            let info = try await qmp.execute("query-migrate")
            switch info["status"] as? String {
            case "completed": return
            case "failed", "cancelled":
                throw MacVMError.engine("迁移失败：\(info["error-desc"] as? String ?? "未知原因")")
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// 结束当前 QEMU 进程并等它退出。先摘下 `process`，它的退出不再触发停止回调，由调用方决定停止原因。
    private func terminate() async {
        guard let process else { return }
        let client = qmp
        self.process = nil
        qmp = nil
        stateLabel = "stopped"
        guard process.isRunning else { return }
        _ = try? await client?.execute("quit")
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
    }

    /// 客户机关机时 QEMU 自行退出，退出码 0。
    private func processExited(_ token: ObjectIdentifier, status: Int32) {
        guard let process, ObjectIdentifier(process) == token else { return }
        self.process = nil
        qmp = nil
        stateLabel = "stopped"
        finish(status == 0 ? .guestShutdown : .error("QEMU 退出码 \(status)"))
    }

    private func finish(_ reason: MachineStopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        lock.release()
        onStop?(reason)
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: reason) }
    }

    /// Windows 安装光盘的引导程序要求开机几秒内按任意键，否则跳过光盘。
    /// 只在前几秒按，免得回车落到安装程序界面上。
    private func pressKeysForInstallMedia() {
        guard config.installMedia.first.map({ $0.lowercased().hasSuffix(".iso") }) == true else { return }
        Task { [weak self] in
            for _ in 0..<8 {
                _ = try? await self?.qmp?.execute("send-key", ["keys": [["type": "qcode", "data": "ret"]]])
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// 把 QEMU 的标准错误照常转给本进程，同时留下最后 `limit` 字节，启动失败时放进错误信息。
private final class StderrTail: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let limit = 4096

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            FileHandle.standardError.write(chunk)
            self?.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
