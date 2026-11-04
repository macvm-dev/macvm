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
    private var bridge: BridgeSession?
    private var gpuDriverSync: Task<Void, Never>?
    private var pageCacheTrim: Task<Void, Never>?

    /// `display` 为 true 时由 QEMU 自己开一个 Cocoa 窗口显示画面。
    public init(bundle: VMBundle, display: Bool = false) throws {
        qemu = try QEMUInstallation.require()
        stopLatch = StopLatch(lock: try BundleLock.acquire(bundle))
        self.bundle = bundle
        self.display = display
        config = try bundle.loadConfig()
        if config.graphicsAcceleration, !qemu.direct3D {
            throw MacVMError.unsupported("\(config.name) 装了 3D 显卡驱动，需要 App 自带的 QEMU（macOS 27 起）；当前的 QEMU 没有 3D，Windows 开机即崩溃")
        }
        try qemu.ensureVars(for: bundle)
        // 主板 UUID 由它算出；较早建的包可能没有。
        if !FileManager.default.fileExists(atPath: bundle.machineIdentifierURL.path) { try MachineIdentity.createGeneric(in: bundle) }
        _ = try QEMUCommand(bundle: bundle, config: config, qemu: qemu).arguments()
    }

    public var canSuspend: Bool { config.supportsSuspend }

    public var supportsLiveShares: Bool { false }

    public func updateShares(_ shares: [ShareConfig]) throws {
        throw MacVMError.unsupported("QEMU 引擎不支持共享目录")
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
            throw MacVMError.unsupported("QEMU 引擎不能接入 ASIF 映像")
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
            throw MacVMError.engine("接入 \(url.lastPathComponent) 失败：\((error as? MacVMError)?.message ?? error.localizedDescription)")
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
            throw MacVMError.engine("推出 \(entry.image.url.lastPathComponent) 失败：\((error as? MacVMError)?.message ?? error.localizedDescription)")
        }
        hotPlugged.removeAll { $0.image.id == id }
        // 设备从总线上摘下之后块设备才不再被占用，在那之前 blockdev-del 会失败。
        for _ in 0..<50 {
            if (try? await qmp.execute("blockdev-del", ["node-name": Self.nodeName(entry.serial)])) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw MacVMError.engine("\(entry.image.url.lastPathComponent) 已从客户机拔下，但 QEMU 没释放它的块设备，文件仍被占用，关机后才能再接入或改动")
    }

    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        try RuntimeDirectory.ensure()
        var outcome = MachineStartOutcome.coldBoot
        if bundle.hasSavedState, !recovery {
            do {
                try await launch(incoming: bundle.savedStateURL)
                try await waitForMigration()
                try await qmp?.execute("cont")
                outcome = .restored
            } catch {
                await terminate()
                outcome = .restoreFailed(describeEngineError(error))
            }
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
        }
        if case .restored = outcome {} else {
            try await launch(incoming: nil)
            pressKeysForInstallMedia()
        }
        stateLabel = "running"
        syncGuestGPUDriver()
        trimGuestPageCache()
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

    /// NAT 下经 QEMU 转发到 Unix socket 的端口，只有 `QEMUCommand.forwardedPorts`；桥接下直连客户机 IP 上的任意端口。
    nonisolated static func connectToGuest(_ bundle: VMBundle, _ config: VMConfig, port: UInt32) throws -> UnixSocket {
        if config.networks.first?.mode == .bridged {
            guard let ip = GuestAddress.current(bundle, config) else { throw MacVMError.io("尚未取得 \(bundle.name) 的 IP 地址") }
            let fd = GuestConnection.tcpConnect(ip, UInt16(port))
            guard fd >= 0 else { throw MacVMError.posix("连接 \(ip):\(port)") }
            return UnixSocket(fd: fd)
        }
        guard QEMUCommand.forwardedPorts.contains(port) else {
            throw MacVMError.unsupported("QEMU 引擎在 NAT 网络下只转发客户机端口 \(QEMUCommand.forwardedPorts.map(String.init).joined(separator: "、"))")
        }
        return try UnixSocket.connect(to: QEMUCommand.portSocket(bundle, port: port).path)
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

    public func screenshot(to url: URL) async throws {
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        try await qmp.execute("screendump", ["filename": url.path, "format": "png"])
    }

    /// 自带的 QEMU 把尺寸告诉客户机（与调整显示窗口大小的效果相同），客户机的显卡驱动决定是否跟随：
    /// Windows 的 viogpu3d 由它的分辨率服务切换，Linux 由桌面环境切换。
    public func resizeDisplay(width: Int, height: Int) throws {
        guard qemu.bundleRoot != nil else { throw MacVMError.unsupported("Homebrew 的 QEMU 不支持运行中调整显示尺寸") }
        guard let qmp else { throw MacVMError.notRunning(bundle.name) }
        Task { _ = try? await qmp.execute("x-macvm-set-display-size", ["width": width, "height": height]) }
    }

    public func openGuestChannel(port: UInt32) async throws -> GuestChannel {
        let bundle = bundle, config = config
        let fd = try await Task.detached { try Self.connectToGuest(bundle, config, port: port).duplicateDescriptor() }.value
        return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
    }

    // MARK: - 进程

    private func launch(incoming: URL?) async throws {
        let qmpPath = QEMUCommand.qmpSocket(bundle).path
        // 能连上说明上一个 QEMU 还在运行（持有锁的进程已不在）；删掉它的 socket 会让它再也无法管理。
        if (try? UnixSocket.connect(to: qmpPath)) != nil {
            throw MacVMError.engine("\(bundle.name) 上次的 QEMU 进程仍在运行，先结束它（ps 中 -name \(bundle.name) 的 qemu-system-aarch64）")
        }
        for path in [QEMUCommand.qmpSocket(bundle), QEMUCommand.vncSocket(bundle), QEMUCommand.spiceSocket(bundle)] + QEMUCommand.forwardedPorts.map({ QEMUCommand.portSocket(bundle, port: $0) }) {
            unlink(path.path)
        }
        var command = QEMUCommand(bundle: bundle, config: config, qemu: qemu)
        command.display = display
        command.incoming = incoming
        let arguments = try command.arguments()

        closeBridge()
        if let net = config.networks.first, net.mode == .bridged {
            BridgeSession.clearAddress(of: bundle)
            let bundle = bundle
            bridge = try await Task.detached { try BridgeSession.open(net, bundle: bundle) }.value
        }

        let process = Process()
        process.executableURL = qemu.binary
        process.arguments = arguments
        // QEMU 与它加载的库可能在当前目录留下日志等文件，别落在调用方的目录里。
        process.currentDirectoryURL = RuntimeDirectory.url
        if !qemu.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(qemu.environment) { $1 }
        }
        process.standardInput = bridge?.fileHandle ?? FileHandle.nullDevice
        let stderr = StderrTail()
        process.standardError = stderr.pipe
        let token = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.processExited(token, status: status) }
        }
        do { try process.run() } catch {
            closeBridge()
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
        gpuDriverSync?.cancel()
        pageCacheTrim?.cancel()
        defer { closeBridge() }
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
        pageCacheTrim?.cancel()
        self.process = nil
        qmp = nil
        closeBridge()
        stateLabel = "stopped"
        finish(status == 0 ? .guestShutdown : .error("QEMU 退出码 \(status)"))
    }

    private func finish(_ reason: MachineStopReason) { stopLatch.fire(reason) }

    private func closeBridge() {
        bridge?.close()
        bridge = nil
    }

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
                FileHandle.standardError.write(Data("macvm: 为 \(name) 读取显卡驱动包失败：\(error)\n".utf8))
                return
            }
            // 代理在客户机登录后才启动，开机慢时要等好几分钟。
            for _ in 0..<Self.agentWaitAttempts {
                do {
                    if try WindowsGPUDriver.push(payload, connect: { try Self.connectToGuest(bundle, config, port: AgentProtocol.port) }) {
                        let rebooting = Self.askAgentToShutDown(bundle, config, reboot: true)
                        let next = rebooting ? "正在重启客户机" : "重启客户机失败，请手动重启"
                        FileHandle.standardError.write(Data("macvm: 已为 \(name) 更新显卡驱动，\(next)\n".utf8))
                    }
                    return
                } catch is WindowsGPUDriver.AgentNotReady {
                    try? await Task.sleep(for: Self.agentWaitInterval)
                    if Task.isCancelled { return }
                } catch {
                    FileHandle.standardError.write(Data("macvm: 为 \(name) 推送显卡驱动失败：\(error)\n".utf8))
                    return
                }
            }
        }
    }

    /// 客户机上报的空闲页由自带的 QEMU 还给宿主，页缓存却不算空闲、一直占着宿主内存：定期请代理把它修剪到
    /// `pageCacheKeep`，腾出的页随之上报。代理回错误（旧版本不认识这个请求）就不再请求；连不上时下次再试。
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
