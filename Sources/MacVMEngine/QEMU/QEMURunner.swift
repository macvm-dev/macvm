public import Foundation
public import MacVMModel

/// 以 QEMU（hvf 加速）子进程运行虚拟机，经 QMP 控制。
@MainActor
public final class QEMURunner: MachineRunner {
    public let bundle: VMBundle
    public let config: VMConfig
    public private(set) var stateLabel = "stopped"
    public var onStop: ((MachineStopReason) -> Void)? {
        get { stopLatch.onStop }
        set { stopLatch.onStop = newValue }
    }

    private let qemu: QEMUInstallation
    private let stopLatch: StopLatch
    private let display: Bool
    private var process: Process?
    private var qmp: QMPClient?
    private var gpuDriverSync: Task<Void, Never>?
    private var pageCacheTrim: Task<Void, Never>?
    private var screenLockSync: Task<Void, Never>?
    /// 从挂起状态恢复期间为真：这时 QEMU 退出由 `start` 当作恢复失败处理，不触发停止回调，只记在 `restoreExited`。
    private var restoring = false
    private var restoreExited = false

    /// `display` 为 true 时由 QEMU 自己开一个 Cocoa 窗口显示画面。
    public init(bundle: VMBundle, display: Bool = false) throws {
        qemu = try QEMUInstallation.require()
        stopLatch = StopLatch(bundle: bundle, lock: try BundleLock.acquire(bundle))
        self.bundle = bundle
        self.display = display
        config = try bundle.loadConfig()
        if config.graphicsAcceleration, !qemu.direct3D {
            throw MacVMError.unsupported(String(l10n: "\(config.name) has the 3D graphics driver installed and needs the QEMU that comes with MacVM (macOS 27 or later); this QEMU has no 3D support, so Windows would crash at startup"))
        }
        try qemu.ensureVars(for: bundle)
        // 主板 UUID 由它算出，包里没有时补建。
        if !FileManager.default.fileExists(atPath: bundle.machineIdentifierURL.path) { try MachineIdentity.createGeneric(in: bundle) }
        _ = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments()
    }

    public var canSuspend: Bool { qemu.canSuspend(config) }

    public var supportsLiveShares: Bool { false }

    public func updateShares(_ shares: [ShareConfig]) throws {
        throw MacVMError.unsupported(String(l10n: "The QEMU engine doesn't support shared folders"))
    }

    // MARK: - 磁盘映像

    /// 按接入顺序排列；`serial` 拼出 QMP 里的块设备 node-name 与 USB 设备 id。
    private var hotPlugged: [(image: AttachedImage, serial: Int)] = []
    private var lastHotPlugSerial = 0

    public var supportsImageHotPlug: Bool { true }

    public var attachedImages: [AttachedImage] { hotPlugged.map(\.image) }

    private static func nodeName(_ serial: Int) -> String { "hpimg\(serial)" }
    private static func deviceID(_ serial: Int) -> String { "hpusb\(serial)" }

    public func attachImage(_ url: URL, readOnly: Bool) async throws -> AttachedImage {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try checkAttachable(url)
        // 按 raw 接入，ASIF 的容器字节会原样露给客户机，客户机一写就毁了映像。
        guard url.pathExtension.lowercased() != "asif" else {
            throw MacVMError.unsupported(String(l10n: "The QEMU engine can't attach ASIF images"))
        }
        lastHotPlugSerial += 1
        let serial = lastHotPlugSerial
        let node = Self.nodeName(serial)
        do {
            try await qmp.execute("blockdev-add", [
                "driver": "raw", "node-name": node, "read-only": readOnly,
                "file": ["driver": "file", "filename": url.path, "read-only": readOnly],
            ])
            do {
                try await qmp.execute("device_add", ["driver": "usb-storage", "id": Self.deviceID(serial), "bus": "usb.0", "drive": node, "removable": true])
            } catch {
                _ = try? await qmp.execute("blockdev-del", ["node-name": node])
                throw error
            }
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't attach \(url.lastPathComponent): \((error as? MacVMError)?.message ?? error.localizedDescription)"))
        }
        let image = AttachedImage(id: UUID(), url: url, readOnly: readOnly)
        hotPlugged.append((image, serial))
        return image
    }

    public func ejectImage(_ id: UUID) async throws {
        guard let entry = hotPlugged.first(where: { $0.image.id == id }) else { return }
        guard let qmp else {
            hotPlugged.removeAll { $0.image.id == id }
            return
        }
        do {
            try await qmp.execute("device_del", ["id": Self.deviceID(entry.serial)])
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't eject \(entry.image.url.lastPathComponent): \((error as? MacVMError)?.message ?? error.localizedDescription)"))
        }
        hotPlugged.removeAll { $0.image.id == id }
        // 设备从总线上摘下之后块设备才不再被占用，在那之前 blockdev-del 会失败。
        for _ in 0..<50 {
            if (try? await qmp.execute("blockdev-del", ["node-name": Self.nodeName(entry.serial)])) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw MacVMError.engine(String(l10n: "\(entry.image.url.lastPathComponent) was removed from the guest, but QEMU is still holding the file; shut down the virtual machine before attaching or changing it again"))
    }

    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        try RuntimeDirectory.ensure()
        var outcome = MachineStartOutcome.coldBoot
        if bundle.hasSavedState, recovery {
            // 冷启动会写磁盘，留着的状态与磁盘从此不一致。
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            outcome = .restoreFailed(String(l10n: "Starting in recovery mode; the suspended state won't be restored"))
        } else if bundle.hasSavedState {
            restoring = true
            restoreExited = false
            defer { restoring = false }
            var connected = false
            do {
                try await launch(incoming: bundle.savedStateURL)
                connected = true
                try await waitForMigration()
                try await qmp?.execute("cont")
                outcome = .restored
            } catch {
                let exited = restoreExited || process?.isRunning == false
                await terminate()
                // QEMU 还活着却连不上控制接口：它还没读挂起状态，状态文件仍可用，留着它；
                // QEMU 已退出或迁移失败时状态不可信，丢弃后冷启动。
                guard connected || exited else { throw error }
                outcome = .restoreFailed(describeEngineError(error))
            }
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
        }
        if case .restored = outcome {} else {
            do { try await launch(incoming: nil) } catch {
                await terminate()
                throw error
            }
            pressKeysForInstallMedia()
        }
        stateLabel = "running"
        stopLatch.started()
        syncGuestGPUDriver()
        trimGuestPageCache()
        screenLockSync = GuestScreenLock.applyAfterBoot(bundle, config: config)
        return outcome
    }

    /// 装了代理的 Windows 请代理关机：它对 ACPI 电源键时常没有反应。代理不可用时再按电源键。
    public func requestStop() throws {
        guard let qmp, process?.isRunning == true else { throw MacVMError.notRunning(bundle.name) }
        let agent = config.os == .windows && config.guestAgent
        let bundle = bundle, config = config
        Task.detached {
            if agent, Self.askAgentToShutDown(bundle, config, reboot: false) { return }
            _ = try? await qmp.execute("system_powerdown")
        }
    }

    nonisolated private static func askAgentToShutDown(_ bundle: VMBundle, _ config: VMConfig, reboot: Bool) -> Bool {
        guard let socket = try? connectToGuest(bundle, config, port: AgentProtocol.port) else { return false }
        return AgentClient.call(.shutdown(reboot: reboot), over: socket, timeout: 3)
    }

    /// 经 QEMU 转发到 Unix socket 的端口，只有 `QEMUCommand.forwardedPorts`。
    nonisolated static func connectToGuest(_ bundle: VMBundle, _ config: VMConfig, port: UInt32) throws -> UnixSocket {
        guard QEMUCommand.forwardedPorts.contains(port) else {
            throw MacVMError.unsupported(String(l10n: "The QEMU engine only forwards guest ports \(QEMUCommand.forwardedPorts.map(String.init).joinedAsList())"))
        }
        let socket = try UnixSocket.connect(to: QEMUCommand.portSocket(bundle, port: port).path)
        if port == AgentProtocol.port { try AgentToken.authenticate(socket, bundle: bundle) }
        return socket
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
        guard config.supportsSuspend else { throw MacVMError.unsupported(String(l10n: "This virtual machine's configuration doesn't support suspending")) }
        guard !qemu.usesVirgl else { throw QEMUInstallation.virglSuspendError }
        if let saved = try? bundle.loadConfig(), saved.audioDiffers(from: config) { throw VMConfig.audioChangedSinceBootError }
        try requireNoAttachedImages()
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

    public func waitUntilStopped() async -> MachineStopReason { await stopLatch.wait() }

    /// `qmp_x_macvm_display_surface` 在客户机关掉 GL 扫描输出时的报错文字。
    private static let noScanoutMessage = "the display has no GL scanout"

    /// virgl 的画面在宿主 GPU 上，`screendump` 只看得到旧的帧缓冲，改读 QEMU 交出的 IOSurface。
    public func screenshot(to url: URL) async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        guard qemu.usesVirgl else {
            try await qmp.execute("screendump", ["filename": url.path, "format": "png"])
            return
        }
        let surface: QMPClient.JSON
        do {
            surface = try await qmp.execute("x-macvm-display-surface")
        } catch MacVMError.engine(let message) where message.hasSuffix(Self.noScanoutMessage) {
            throw MacVMError.engine(String(l10n: "The guest isn't showing anything right now (its display is asleep, or it's still on the firmware screen during startup); wake it and try again"))
        }
        guard let id = (surface["iosurface"] as? NSNumber)?.uint32Value else {
            throw MacVMError.engine(String(l10n: "QEMU didn't provide an IOSurface for the display"))
        }
        try IOSurfaceImage.writePNG(surfaceID: id, to: url)
    }

    /// 自带的 QEMU 把尺寸告诉客户机（与调整显示窗口大小的效果相同），客户机的显卡驱动决定是否跟随：
    /// Windows 的 viogpu3d 由它的分辨率服务切换，Linux 由桌面环境切换。
    public func resizeDisplay(width: Int, height: Int) throws {
        guard qemu.bundleRoot != nil else { throw MacVMError.unsupported(String(l10n: "Homebrew's QEMU can't resize the display while the virtual machine is running")) }
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        Task { _ = try? await qmp.execute("x-macvm-set-display-size", ["width": width, "height": height]) }
    }

    /// `QEMUCommand.forwardedPorts` 以外的端口先经 HMP 的 `hostfwd_add` 给用户态网络加一条到 Unix socket 的转发，
    /// 本次 QEMU 进程里一直留着。客户机上的服务要监听 `10.0.2.15` 或任意地址，只听回环的连不到。
    public func openGuestChannel(port: UInt32) async throws -> GuestChannel {
        let bundle = bundle, config = config
        if !QEMUCommand.forwardedPorts.contains(port) { try await addHostForward(port) }
        let fd = try await Task.detached {
            QEMUCommand.forwardedPorts.contains(port)
                ? try Self.connectToGuest(bundle, config, port: port).duplicateDescriptor()
                : try UnixSocket.connect(to: QEMUCommand.portSocket(bundle, port: port).path).duplicateDescriptor()
        }.value
        return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
    }

    /// 本次 QEMU 进程里经 `addHostForward` 加过（或正在加）的端口。
    private var hostForwards: [UInt32: Task<Void, any Error>] = [:]

    private func addHostForward(_ port: UInt32) async throws {
        if let pending = hostForwards[port] { return try await pending.value }
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        let path = QEMUCommand.portSocket(bundle, port: port).path
        let task = Task {
            unlink(path)
            try await qmp.human("hostfwd_add net0 unix:\(path)-:\(port)")
        }
        hostForwards[port] = task
        do { try await task.value } catch {
            hostForwards[port] = nil
            throw error
        }
    }

    // MARK: - 进程

    private func launch(incoming: URL?) async throws {
        let qmpPath = QEMUCommand.qmpSocket(bundle).path
        // 能连上说明上一个 QEMU 还在运行（持有锁的进程已不在）；删掉它的 socket 会让它再也无法管理。
        if (try? UnixSocket.connect(to: qmpPath)) != nil {
            throw MacVMError.engine(String(l10n: "An earlier QEMU process for \(bundle.name) is still running; quit it first (look for qemu-system-aarch64 with -name \(bundle.name) in ps)"))
        }
        for path in [QEMUCommand.qmpSocket(bundle), QEMUCommand.vncSocket(bundle), QEMUCommand.spiceSocket(bundle)] + QEMUCommand.forwardedPorts.map({ QEMUCommand.portSocket(bundle, port: $0) }) {
            unlink(path.path)
        }
        var command = QEMUCommand(bundle: bundle, config: config, qemu: qemu)
        command.display = display
        command.incoming = incoming
        let arguments = try command.arguments()

        let process = Process()
        process.executableURL = qemu.binary
        process.arguments = arguments
        // QEMU 与它加载的库可能在当前目录留下日志等文件，别落在调用方的目录里。
        process.currentDirectoryURL = RuntimeDirectory.url
        if !qemu.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(qemu.environment) { $1 }
        }
        process.standardInput = FileHandle.nullDevice
        let stderr = StderrTail()
        process.standardError = stderr.pipe
        let token = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.processExited(token, status: status) }
        }
        do { try process.run() } catch {
            throw MacVMError.engine(String(l10n: "Couldn't start QEMU: \(error.localizedDescription)"))
        }
        self.process = process
        stateLabel = "starting"

        let client: QMPClient
        do {
            client = try await QMPClient.connect(to: qmpPath, timeout: 15) { [process = Unchecked(value: process)] in process.value.isRunning }
        } catch {
            let detail = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw detail.isEmpty ? error : MacVMError.engine(String(l10n: "QEMU didn't start: \(detail)"))
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
                throw MacVMError.engine(String(l10n: "Couldn't save or restore the virtual machine state: \(info["error-desc"] as? String ?? String(l10n: "unknown reason"))"))
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// 结束当前 QEMU 进程并等它退出。先摘下 `process`，它的退出不再触发停止回调，由调用方决定停止原因。
    /// 主循环卡住时 QMP 不应答、SIGTERM 也没人处理，所以 `quit` 只等有限时间，之后依次 SIGTERM、SIGKILL。
    private func terminate() async {
        let current = process, client = qmp
        detachProcess()
        guard let process = current, process.isRunning else { return }
        if let client { Task.detached { _ = try? await client.execute("quit") } }
        if await Self.waitForExit(process, within: .seconds(5)) { return }
        process.terminate()
        if await Self.waitForExit(process, within: .seconds(3)) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await Self.waitForExit(process, within: .seconds(3))
    }

    private static func waitForExit(_ process: Process, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return !process.isRunning
    }

    /// 摘下当前 QEMU 进程与它的控制连接，停掉依附于这次运行的后台任务。
    private func detachProcess() {
        gpuDriverSync?.cancel()
        pageCacheTrim?.cancel()
        screenLockSync?.cancel()
        for port in hostForwards.keys { unlink(QEMUCommand.portSocket(bundle, port: port).path) }
        hostForwards.removeAll()
        process = nil
        qmp = nil
        stateLabel = "stopped"
    }

    /// 客户机关机时 QEMU 自行退出，退出码 0。
    private func processExited(_ token: ObjectIdentifier, status: Int32) {
        guard let process, ObjectIdentifier(process) == token else { return }
        detachProcess()
        if restoring {
            restoreExited = true
            return
        }
        finish(status == 0 ? .guestShutdown : .error(String(l10n: "QEMU exited with code \(status)")))
    }

    private func finish(_ reason: MachineStopReason) { stopLatch.fire(reason) }

    /// 开了 3D 加速的 Windows：代理上线后把自带的驱动包推过去。驱动要与自带 QEMU 的图形组件配套，
    /// 升级 App 换了图形组件而客户机还是旧驱动时，桌面合成会崩溃；换了驱动就重启客户机，桌面合成才用上新驱动。
    private func syncGuestGPUDriver() {
        guard config.os == .windows, config.guestAgent, config.graphicsAcceleration, let zip = WindowsGPUDriver.package(qemu) else { return }
        let bundle = bundle, config = config
        let name = bundle.name
        gpuDriverSync?.cancel()
        gpuDriverSync = Task.detached {
            let payload: WindowsGPUDriver.Payload
            do { payload = try WindowsGPUDriver.Payload(contentsOf: zip) } catch {
                FileHandle.standardError.write(Data("macvm: reading the graphics driver package for \(name) failed: \(error)\n".utf8))
                return
            }
            // 代理在客户机登录后才启动，开机慢时要等好几分钟。
            for _ in 0..<Self.agentWaitAttempts {
                do {
                    if try WindowsGPUDriver.push(payload, connect: { try Self.connectToGuest(bundle, config, port: AgentProtocol.port) }) {
                        let rebooting = Self.askAgentToShutDown(bundle, config, reboot: true)
                        let next = rebooting ? "restarting the guest" : "restarting the guest failed; restart it manually"
                        FileHandle.standardError.write(Data("macvm: updated the graphics driver for \(name); \(next)\n".utf8))
                    }
                    return
                } catch is WindowsGPUDriver.AgentNotReady {
                    try? await Task.sleep(for: Self.agentWaitInterval)
                    if Task.isCancelled { return }
                } catch {
                    FileHandle.standardError.write(Data("macvm: pushing the graphics driver to \(name) failed: \(error)\n".utf8))
                    return
                }
            }
        }
    }

    /// 客户机上报的空闲页由自带的 QEMU 还给宿主，页缓存却不算空闲、一直占着宿主内存：定期请代理把它修剪到
    /// `pageCacheKeep`，腾出的页随之上报。代理回错误（不支持这个请求）就不再请求；连不上时下次再试。
    private func trimGuestPageCache() {
        guard config.os == .linux, config.guestAgent, qemu.returnsFreedGuestMemory else { return }
        let bundle = bundle, config = config
        pageCacheTrim?.cancel()
        pageCacheTrim = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pageCacheTrimInterval)
                guard !Task.isCancelled, let socket = try? Self.connectToGuest(bundle, config, port: AgentProtocol.port) else { continue }
                socket.setTimeout(seconds: Self.pageCacheTrimTimeout)
                let request = AgentProtocol.Request.trimCache(keep: Self.pageCacheKeep)
                guard let response = try? socket.exchange(request, as: AgentProtocol.Response.self) else { continue }
                if !response.ok { return }
            }
        }
    }

    private nonisolated static let pageCacheTrimInterval: Duration = .seconds(60)
    private nonisolated static let pageCacheKeep: UInt64 = 256 << 20
    private nonisolated static let pageCacheTrimTimeout = 10

    private nonisolated static let agentWaitAttempts = 120
    private nonisolated static let agentWaitInterval: Duration = .seconds(5)

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
