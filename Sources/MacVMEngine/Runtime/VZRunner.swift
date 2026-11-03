public import Foundation
public import MacVMModel
@preconcurrency public import Virtualization

/// 持有一台运行中的虚拟机。
///
/// 全部在主线程：`VZVirtualMachineView` 要求虚拟机建在主队列上，且 VZ 把客户机放在独立的
/// XPC 进程里执行，主线程只处理控制调用与回调，不承载 vCPU。
@MainActor
public final class VZRunner: NSObject, MachineRunner {
    public typealias StopReason = MachineStopReason

    public let bundle: VMBundle
    public let config: VMConfig
    public let virtualMachine: VZVirtualMachine
    private let vzConfiguration: VZVirtualMachineConfiguration
    public private(set) var stopReason: StopReason?

    /// 虚拟机停止后回调一次。
    public var onStop: ((StopReason) -> Void)?

    private let lock: BundleLock
    private var stopWaiters: [CheckedContinuation<StopReason, Never>] = []

    public init(bundle: VMBundle, console: ConfigBuilder.Console = .none) throws {
        guard VZVirtualMachine.isSupported else {
            throw MacVMError.unsupported("本机不支持虚拟化（需要 Apple Silicon，且进程签名带 com.apple.security.virtualization）")
        }
        lock = try BundleLock.acquire(bundle)
        self.bundle = bundle
        config = try bundle.loadConfig()
        var builder = ConfigBuilder(bundle: bundle, config: config)
        builder.console = console
        vzConfiguration = try builder.build()
        virtualMachine = VZVirtualMachine(configuration: vzConfiguration)
        super.init()
        virtualMachine.delegate = self
    }

    /// 开机输出尺寸是为 Windows 显示驱动的帧缓冲预留的最大尺寸。驱动按加载时读到的尺寸分配帧缓冲，
    /// 所以等代理上线（驱动已加载）后才改回配置的尺寸，并请代理切换分辨率。
    private func restoreDisplayAfterBoot() {
        guestDisplaySync?.cancel()
        guestDisplaySync = Task { [weak self] in
            for _ in 0..<Self.bootDisplayAttempts {
                guard let self, !Task.isCancelled else { return }
                if let ip = guestIP, await Task.detached(operation: { Self.callAgent(ip, .info) }).value {
                    guestDisplayReady = true
                    let size = requestedDisplaySize ?? (config.display.width, config.display.height)
                    try? resizeDisplay(width: size.0, height: size.1)
                    return
                }
                try? await Task.sleep(for: Self.guestDisplayRetryInterval)
            }
        }
    }

    /// Windows 的显示驱动不跟随输出尺寸，改完尺寸后请客户机代理切换分辨率。驱动处理尺寸变化要一点时间，
    /// 代理也可能还没上线，所以失败后每 `guestDisplayRetryInterval` 重试，最多 `attempts` 次。
    /// 新的请求会取消尚未完成的旧请求。
    private func syncGuestDisplay(width: Int, height: Int, attempts: Int) {
        guestDisplaySync?.cancel()
        guestDisplaySync = Task { [weak self] in
            for _ in 0..<attempts {
                guard let self, !Task.isCancelled else { return }
                if let ip = guestIP {
                    let ok = await Task.detached { Self.callAgent(ip, .display(width: width, height: height)) }.value
                    if ok { return }
                }
                try? await Task.sleep(for: Self.guestDisplayRetryInterval)
            }
        }
    }

    private var guestDisplaySync: Task<Void, Never>?
    /// 开机后代理上线前为 false，期间的尺寸请求只记在 `requestedDisplaySize`。
    private lazy var guestDisplayReady = config.os != .windows || !config.guestAgent
    private var requestedDisplaySize: (Int, Int)?
    private var pendingResize: Task<Void, Never>?
    private static let guestDisplayRetryInterval = Duration.seconds(1)
    /// 拖动窗口时尺寸连续变化，停下这么久后才真正调整。
    private static let resizeDebounce = Duration.milliseconds(300)
    /// 开机后等代理上线的最长次数（按 `guestDisplayRetryInterval` 计）。
    private static let bootDisplayAttempts = 180
    private static let resizeDisplayAttempts = 10

    private var guestIP: String? { config.networks.first?.macAddress.flatMap { DHCPLeases.ipAddress(forMAC: $0) } }

    public var state: VZVirtualMachine.State { virtualMachine.state }
    public var stateLabel: String { virtualMachine.state.label }

    public var canSuspend: Bool {
        guard config.supportsSuspend, #available(macOS 14, *) else { return false }
        return (try? vzConfiguration.validateSaveRestoreSupport()) != nil
    }

    /// 存在挂起状态时从它恢复，否则冷启动。恢复失败会丢弃状态文件后冷启动，
    /// 因为状态与磁盘已不一致，留着只会每次都失败。
    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        var outcome = MachineStartOutcome.coldBoot
        if bundle.hasSavedState, !recovery, #available(macOS 14, *) {
            do {
                try await restore()
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                return .restored
            } catch {
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                outcome = .restoreFailed(Self.describe(error))
            }
        }
        if config.os == .macOS {
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = recovery
            var provisioning = false
            if #available(macOS 27, *) { provisioning = try MacOSProvisioning.apply(to: options, bundle: bundle) }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                virtualMachine.start(options: options) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
            if provisioning { MacOSProvisioning.markApplied(bundle) }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                virtualMachine.start { c.resume(with: $0) }
            }
            if config.os == .windows, config.guestAgent { restoreDisplayAfterBoot() }
        }
        return outcome
    }

    /// VZ 的错误把具体原因放在 underlying error 里，一并带上。
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain)#\(ns.code) \(ns.localizedDescription)"]
        if let reason = ns.localizedFailureReason { parts.append(reason) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append(describe(underlying)) }
        return parts.joined(separator: "；")
    }

    /// 向客户机发送关机请求（相当于按电源键），客户机可能忽略。
    /// Windows 收不到 VZ 的电源键事件，改请客户机代理关机，没有代理时经 SSH 执行关机命令。
    public func requestStop() throws {
        if config.os == .windows, let ip = guestIP {
            if config.guestAgent, Self.callAgent(ip, .shutdown(reboot: false)) { return }
            if let user = config.guestUser {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ssh")
                process.arguments = ["-q", "-T", "-i", SSHKeys.privateKeyURL.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                                     "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
                                     "\(user)@\(ip)", "shutdown /s /t 0"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { return }
            }
        }
        guard virtualMachine.canRequestStop else { throw MacVMError.notRunning(bundle.name) }
        do { try virtualMachine.requestStop() } catch {
            throw MacVMError.engine("请求关机失败：\(error.localizedDescription)")
        }
    }

    /// 经 NAT 直连 Windows 客户机的代理发一个请求，返回是否成功。
    nonisolated private static func callAgent(_ ip: String, _ request: AgentProtocol.Request) -> Bool {
        let fd = GuestConnection.tcpConnect(ip, UInt16(AgentProtocol.port))
        guard fd >= 0 else { return false }
        let socket = UnixSocket(fd: fd)
        socket.setTimeout(seconds: 3)
        guard let data = try? JSONEncoder().encode(request), (try? socket.writeLine(data)) != nil,
              let line = try? socket.readLine(),
              let response = try? JSONDecoder().decode(AgentProtocol.Response.self, from: line) else { return false }
        return response.ok
    }

    /// 立即断电，未写回的客户机数据会丢失。
    public func forceStop() async throws {
        guard virtualMachine.canStop else { throw MacVMError.notRunning(bundle.name) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.stop { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        finish(.forced)
    }

    public func pause() async throws {
        guard virtualMachine.canPause else { throw MacVMError.notRunning(bundle.name) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.pause { c.resume(with: $0) }
        }
    }

    public func resume() async throws {
        guard virtualMachine.canResume else { throw MacVMError.notRunning(bundle.name) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.resume { c.resume(with: $0) }
        }
    }

    /// 暂停、把内存与设备状态写进包内后断电；下次 `start` 从该状态继续。
    public func suspend() async throws {
        guard canSuspend, #available(macOS 14, *) else {
            throw MacVMError.unsupported("该虚拟机的配置不支持挂起")
        }
        if virtualMachine.state == .running { try await pause() }
        let url = bundle.savedStateURL
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.saveMachineStateTo(url: url) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.stop { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        finish(.suspended)
    }

    /// 连接客户机内监听的 vsock 端口。返回的连接须保持引用直到用完。
    public func connectToGuest(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw MacVMError.unsupported("虚拟机没有 vsock 设备")
        }
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<VZVirtioSocketConnection>, any Error>) in
                device.connect(toPort: port) { c.resume(with: $0.map(Unchecked.init)) }
            }.value
        } catch {
            throw MacVMError.notRunning("客户机 vsock 端口 \(port) 无人监听")
        }
    }

    /// VZ 没有截取画面的接口，画面只存在于 `VZVirtualMachineView` 里。
    public func screenshot(to url: URL) async throws {
        throw MacVMError.unsupported("VZ 引擎不支持截屏")
    }

    /// Windows 没有 VZ 能用的 vsock 驱动，改经 NAT 网络连客户机 IP 上的同号 TCP 端口。
    public func openGuestChannel(port: UInt32) async throws -> GuestChannel {
        if config.os == .windows {
            guard let ip = guestIP else {
                throw MacVMError.io("尚未取得 \(bundle.name) 的 IP 地址")
            }
            let fd = await Task.detached { GuestConnection.tcpConnect(ip, UInt16(port)) }.value
            guard fd >= 0 else { throw MacVMError.io("连接 \(ip):\(port) 失败：\(String(cString: strerror(errno)))") }
            return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
        }
        let connection = Unchecked(value: try await connectToGuest(port: port))
        return GuestChannel(fileDescriptor: connection.value.fileDescriptor, close: { connection.value.close() })
    }

    /// 改变显示输出尺寸。Windows 客户机经代理切换分辨率，连续调用时只处理最后一次。
    public func resizeDisplay(width: Int, height: Int) throws {
        guard let display = virtualMachine.graphicsDevices.first?.displays.first else { throw MacVMError.unsupported("\(bundle.name) 没有显示设备") }
        guard config.os == .windows else {
            try Self.reconfigure(display, width: width, height: height)
            return
        }
        guard WindowsSupport.fitsDisplay(width: width, height: height) else {
            let max = WindowsSupport.maxDisplaySize
            throw MacVMError.invalidConfig("Windows 客户机的分辨率最大 \(max.width)x\(max.height)")
        }
        guard guestDisplayReady else {
            requestedDisplaySize = (width, height)
            return
        }
        pendingResize?.cancel()
        pendingResize = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard let self, !Task.isCancelled, (try? Self.reconfigure(display, width: width, height: height)) != nil else { return }
            syncGuestDisplay(width: width, height: height, attempts: Self.resizeDisplayAttempts)
        }
    }

    private static func reconfigure(_ display: VZGraphicsDisplay, width: Int, height: Int) throws {
        do { try display.reconfigure(sizeInPixels: CGSize(width: width, height: height)) } catch {
            throw MacVMError.engine("调整显示尺寸失败：\(error.localizedDescription)")
        }
    }

    /// 等到虚拟机停止并返回原因。
    public func waitUntilStopped() async -> StopReason {
        if let stopReason { return stopReason }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    @available(macOS 14, *)
    private func restore() async throws {
        let url = bundle.savedStateURL
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            virtualMachine.restoreMachineStateFrom(url: url) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        try await resume()
    }

    private func finish(_ reason: StopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        onStop?(reason)
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: reason) }
    }
}

extension VZRunner: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(.guestShutdown) }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(.error(message)) }
    }
}

extension VZVirtualMachine.State {
    public var label: String {
        switch self {
        case .stopped: "stopped"
        case .running: "running"
        case .paused: "paused"
        case .error: "error"
        case .starting: "starting"
        case .pausing: "pausing"
        case .resuming: "resuming"
        case .stopping: "stopping"
        case .saving: "saving"
        case .restoring: "restoring"
        @unknown default: "unknown"
        }
    }
}
