public import Foundation
public import MacVMModel
@preconcurrency public import Virtualization

/// 持有一台运行中的虚拟机。
///
/// 全部在主线程：`VZVirtualMachineView` 要求虚拟机建在主队列上，且 VZ 把客户机放在独立的
/// XPC 进程里执行，主线程只处理控制调用与回调，不承载 vCPU。
@MainActor
public final class VZRunner: NSObject, MachineRunner {
    public let bundle: VMBundle
    public let config: VMConfig
    public let virtualMachine: VZVirtualMachine
    private let vzConfiguration: VZVirtualMachineConfiguration
    private let stopLatch: StopLatch

    /// 虚拟机停止后回调一次。
    public var onStop: ((MachineStopReason) -> Void)? {
        get { stopLatch.onStop }
        set { stopLatch.onStop = newValue }
    }

    public init(bundle: VMBundle, console: ConfigBuilder.Console = .none) throws {
        guard VZVirtualMachine.isSupported else {
            throw MacVMError.unsupported("本机不支持虚拟化（需要 Apple Silicon，且进程签名带 com.apple.security.virtualization）")
        }
        stopLatch = StopLatch(lock: try BundleLock.acquire(bundle))
        self.bundle = bundle
        config = try bundle.loadConfig()
        var builder = ConfigBuilder(bundle: bundle, config: config)
        builder.console = console
        vzConfiguration = try builder.build()
        virtualMachine = VZVirtualMachine(configuration: vzConfiguration)
        super.init()
        virtualMachine.delegate = self
    }

    /// 开机后等代理上线，请它把 virtio-gpu 设为唯一的主显示器、取 `WindowsSupport.displaySize`：
    /// 引导垫片的帧缓冲在 Windows 里是另一块显示器，常被选为主显示器，宿主却看不到它。
    private func fitGuestDisplayAfterBoot() {
        guard let mac = guestMAC else { return }
        guestDisplayFit = Task.detached {
            let size = WindowsSupport.displaySize
            for _ in 0..<Self.guestDisplayAttempts {
                guard !Task.isCancelled else { return }
                if let ip = DHCPLeases.ipAddress(forMAC: mac),
                   Self.callAgent(ip, .display(width: size.width, height: size.height), timeout: Self.displaySwitchTimeout) {
                    return
                }
                try? await Task.sleep(for: Self.guestDisplayRetryInterval)
            }
        }
    }

    private var guestDisplayFit: Task<Void, Never>?
    nonisolated private static let guestDisplayRetryInterval = Duration.seconds(1)
    /// 开机后等代理上线的最长次数（按 `guestDisplayRetryInterval` 计）。
    nonisolated private static let guestDisplayAttempts = 180
    /// 客户机切换显示设置要重建桌面，可能耗时数秒。
    nonisolated private static let displaySwitchTimeout = 20

    private var guestMAC: String? { config.networks.first?.macAddress }
    /// 读 DHCP 租约文件，不要在主线程反复调用。
    private var guestIP: String? { guestMAC.flatMap { DHCPLeases.ipAddress(forMAC: $0) } }

    public var stateLabel: String { virtualMachine.state.label }

    public var canSuspend: Bool {
        guard config.supportsSuspend else { return false }
        return (try? vzConfiguration.validateSaveRestoreSupport()) != nil
    }

    /// 存在挂起状态时从它恢复，否则冷启动。恢复失败会丢弃状态文件后冷启动，
    /// 因为状态与磁盘已不一致，留着只会每次都失败。
    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        var outcome = MachineStartOutcome.coldBoot
        if bundle.hasSavedState, !recovery {
            do {
                try await restore()
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                return .restored
            } catch {
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                outcome = .restoreFailed(describeEngineError(error))
            }
        }
        if config.os == .macOS {
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = recovery
            var provisioning = false
            if #available(macOS 27, *) { provisioning = try MacOSProvisioning.apply(to: options, bundle: bundle) }
            try await virtualMachine.start(options: options)
            if provisioning { MacOSProvisioning.markApplied(bundle) }
        } else {
            try await virtualMachine.start()
            if config.os == .windows, config.guestAgent { fitGuestDisplayAfterBoot() }
        }
        return outcome
    }

    /// 向客户机发送关机请求，客户机可能忽略。Linux 按电源键。
    /// Windows 收不到 VZ 的电源键事件，macOS 收到也不关机：改在后台请客户机代理关机，
    /// 没有代理时经 SSH 执行关机命令，都不行才按电源键。
    public func requestStop() throws {
        guard virtualMachine.canRequestStop else { throw MacVMError.notRunning(bundle.name) }
        switch config.os {
        case .linux:
            try pressPowerButton()
        case .windows:
            guard let mac = guestMAC else { return try pressPowerButton() }
            let agent = config.guestAgent, user = config.guestUser
            Task.detached { [weak self] in
                if let ip = DHCPLeases.ipAddress(forMAC: mac) {
                    if agent, Self.callAgent(ip, .shutdown(reboot: false)) { return }
                    if let user, Self.sshShutdown(user: user, ip: ip) { return }
                }
                try? await self?.pressPowerButton()
            }
        case .macOS:
            Task { [weak self] in
                guard let self, await !shutdownMacOSGuest() else { return }
                try? pressPowerButton()
            }
        }
    }

    /// 经 vsock 请代理关机；没有代理时经 SSH 用包内保存的客户机密码 sudo 关机。返回客户机是否接受。
    private func shutdownMacOSGuest() async -> Bool {
        if config.guestAgent, let connection = try? await connectToGuest(port: AgentProtocol.port) {
            let held = Unchecked(value: connection)
            defer { held.value.close() }
            // `UnixSocket` 用完会关掉自己的 fd，交给它一份副本，连接本身由 `held` 关闭。
            let fd = dup(connection.fileDescriptor)
            if fd >= 0, await Task.detached(operation: {
                AgentClient.call(.shutdown(reboot: false), over: UnixSocket(fd: fd), timeout: 3)
            }).value {
                return true
            }
        }
        guard let user = config.guestUser, let ip = guestIP, let password = GuestCredentials.password(for: bundle) else { return false }
        return await Task.detached { Self.sshSudoShutdown(user: user, ip: ip, password: password) }.value
    }

    /// sudo 认证通过后在客户机后台延迟一秒关机，ssh 先正常退出；返回 sudo 是否成功。
    nonisolated private static func sshSudoShutdown(user: String, ip: String, password: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        let remote = #"sudo -S -p '' /bin/sh -c 'nohup /bin/sh -c "sleep 1; /sbin/shutdown -h now" >/dev/null 2>&1 &'"#
        process.arguments = ["-q", "-T"] + SSHConfig.keyArguments(proxyCommand: nil)
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "\(user)@\(ip)", remote]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        guard exited.wait(timeout: .now() + sshShutdownTimeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    nonisolated private static let sshShutdownTimeout: TimeInterval = 20

    private func pressPowerButton() throws {
        do { try virtualMachine.requestStop() } catch {
            throw MacVMError.engine("请求关机失败：\(error.localizedDescription)")
        }
    }

    /// 发出 SSH 关机命令后即返回，返回是否成功启动了 ssh。
    nonisolated private static func sshShutdown(user: String, ip: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = ["-q", "-T"] + SSHConfig.keyArguments(proxyCommand: nil)
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "\(user)@\(ip)", "shutdown /s /t 0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    /// 经 NAT 直连 Windows 客户机的代理发一个请求，返回是否成功。
    nonisolated private static func callAgent(_ ip: String, _ request: AgentProtocol.Request, timeout: Int = 3) -> Bool {
        let fd = GuestConnection.tcpConnect(ip, UInt16(AgentProtocol.port))
        guard fd >= 0 else { return false }
        return AgentClient.call(request, over: UnixSocket(fd: fd), timeout: timeout)
    }

    /// 立即断电，未写回的客户机数据会丢失。
    public func forceStop() async throws {
        guard virtualMachine.canStop else { throw MacVMError.notRunning(bundle.name) }
        try await virtualMachine.stop()
        finish(.forced)
    }

    public func pause() async throws {
        guard virtualMachine.canPause else { throw MacVMError.notRunning(bundle.name) }
        try await virtualMachine.pause()
    }

    public func resume() async throws {
        guard virtualMachine.canResume else { throw MacVMError.notRunning(bundle.name) }
        try await virtualMachine.resume()
    }

    /// 暂停、把内存与设备状态写进包内后断电；下次 `start` 从该状态继续。
    public func suspend() async throws {
        guard canSuspend else {
            throw MacVMError.unsupported("该虚拟机的配置不支持挂起")
        }
        if virtualMachine.state == .running { try await pause() }
        let url = bundle.savedStateURL
        try await virtualMachine.saveMachineStateTo(url: url)
        try await virtualMachine.stop()
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
            guard fd >= 0 else { throw MacVMError.posix("连接 \(ip):\(port)") }
            return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
        }
        let connection = Unchecked(value: try await connectToGuest(port: port))
        return GuestChannel(fileDescriptor: connection.value.fileDescriptor, close: { connection.value.close() })
    }

    /// 改变显示输出尺寸。
    public func resizeDisplay(width: Int, height: Int) throws {
        guard config.os != .windows else { throw WindowsSupport.fixedDisplayError }
        guard let display = virtualMachine.graphicsDevices.first?.displays.first else { throw MacVMError.unsupported("\(bundle.name) 没有显示设备") }
        do { try display.reconfigure(sizeInPixels: CGSize(width: width, height: height)) } catch {
            throw MacVMError.engine("调整显示尺寸失败：\(error.localizedDescription)")
        }
    }

    /// 等到虚拟机停止并返回原因。
    public func waitUntilStopped() async -> MachineStopReason { await stopLatch.wait() }

    private func restore() async throws {
        let url = bundle.savedStateURL
        try await virtualMachine.restoreMachineStateFrom(url: url)
        try await resume()
    }

    private func finish(_ reason: MachineStopReason) {
        guestDisplayFit?.cancel()
        stopLatch.fire(reason)
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
