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

    init(bundle: VMBundle, console: ConfigBuilder.Console = .none) throws {
        guard VZVirtualMachine.isSupported else {
            throw MacVMError.unsupported(String(l10n: "This Mac doesn't support virtualization (it needs Apple silicon and an app signed with the com.apple.security.virtualization entitlement)"))
        }
        stopLatch = StopLatch(bundle: bundle, lock: try BundleLock.acquire(bundle))
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
        guard config.networks.first?.macAddress != nil else { return }
        let bundle = bundle, config = config
        guestDisplayFit = Task.detached {
            let size = WindowsSupport.displaySize
            for _ in 0..<Self.guestDisplayAttempts {
                guard !Task.isCancelled else { return }
                if let ip = GuestAddress.current(bundle, config),
                   Self.callAgent(bundle, ip, .display(width: size.width, height: size.height), timeout: Self.displaySwitchTimeout) {
                    return
                }
                try? await Task.sleep(for: Self.guestDisplayRetryInterval)
            }
        }
    }

    private var guestDisplayFit: Task<Void, Never>?
    private var screenLockSync: Task<Void, Never>?
    private var staticAddressSync: Task<Void, Never>?
    private var bridgedAddressWatch: Task<Void, Never>?
    nonisolated private static let guestDisplayRetryInterval = Duration.seconds(1)
    /// 开机后等代理上线的最长次数（按 `guestDisplayRetryInterval` 计）。
    nonisolated private static let guestDisplayAttempts = 180
    /// 客户机切换显示设置要重建桌面，可能耗时数秒。
    nonisolated private static let displaySwitchTimeout = 20

    /// 读文件，不要在主线程反复调用。
    private var guestIP: String? { GuestAddress.current(bundle, config) }

    public var stateLabel: String { virtualMachine.state.label }

    public var supportsLiveShares: Bool { automountShareDevice != nil }

    /// macOS 客户机的共享目录设备；从没有它的挂起状态恢复的这次开机里为 nil。
    private var automountShareDevice: VZVirtioFileSystemDevice? {
        guard config.os == .macOS else { return nil }
        return virtualMachine.directorySharingDevices.lazy
            .compactMap { $0 as? VZVirtioFileSystemDevice }
            .first { $0.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag }
    }

    /// 客户机里 `My Shared Files` 下的目录随之增减。
    public func updateShares(_ shares: [ShareConfig]) throws {
        guard let device = automountShareDevice else {
            throw MacVMError.unsupported(String(l10n: "Shut down \(bundle.name) before changing its shared folders"))
        }
        device.share = try ConfigBuilder.macOSShare(shares, in: bundle)
    }

    // MARK: - 磁盘映像

    /// 按接入顺序排列。
    private var hotPlugged: [(image: AttachedImage, device: VZUSBMassStorageDevice)] = []

    public var supportsImageHotPlug: Bool { !virtualMachine.usbControllers.isEmpty }

    public var attachedImages: [AttachedImage] { hotPlugged.map(\.image) }

    public func attachImage(_ url: URL, readOnly: Bool) async throws -> AttachedImage {
        guard let controller = virtualMachine.usbControllers.first else {
            throw MacVMError.unsupported(String(l10n: "\(bundle.name) has no USB controller, so you can't attach disk images to it"))
        }
        guard virtualMachine.state == .running || virtualMachine.state == .paused else { throw MacVMError.notRunning(bundle.name) }
        try checkAttachable(url)
        let attachment = try ConfigBuilder.diskAttachment(url: url, readOnly: readOnly, caching: .automatic, sync: readOnly ? .none : .fsync)
        let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        do {
            try await controller.attach(device: device)
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't attach \(url.lastPathComponent): \(describeEngineError(error))"))
        }
        let image = AttachedImage(id: device.uuid, url: url, readOnly: readOnly)
        hotPlugged.append((image, device))
        return image
    }

    public func ejectImage(_ id: UUID) async throws {
        guard let index = hotPlugged.firstIndex(where: { $0.image.id == id }) else { return }
        let (image, device) = hotPlugged[index]
        guard let controller = device.usbController else {
            hotPlugged.remove(at: index)
            return
        }
        do {
            try await controller.detach(device: device)
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't eject \(image.url.lastPathComponent): \(describeEngineError(error))"))
        }
        hotPlugged.removeAll { $0.image.id == id }
    }

    public var canSuspend: Bool {
        guard config.supportsSuspend else { return false }
        return (try? vzConfiguration.validateSaveRestoreSupport()) != nil
    }

    /// 存在挂起状态时从它恢复，否则冷启动。恢复失败或以恢复模式启动时丢弃状态文件后冷启动：
    /// 冷启动会写磁盘，状态与磁盘从此不一致，留着下次只会恢复出错或损坏文件系统。
    /// 启动失败时按停止处理：释放包锁并回调 `onStop`，再抛出原错误。
    @discardableResult
    public func start(recovery: Bool = false) async throws -> MachineStartOutcome {
        do {
            let outcome = try await boot(recovery: recovery)
            stopLatch.started()
            screenLockSync = GuestScreenLock.applyAfterBoot(bundle, config: config)
            staticAddressSync = GuestStaticIPv4.applyAfterBoot(bundle, config: config)
            bridgedAddressWatch = BridgedAddress.watch(bundle, config: config)
            return outcome
        } catch {
            finish(.error(describeEngineError(error)))
            throw error
        }
    }

    private func boot(recovery: Bool) async throws -> MachineStartOutcome {
        var outcome = MachineStartOutcome.coldBoot
        if bundle.hasSavedState, recovery {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            outcome = .restoreFailed(String(l10n: "Starting in recovery mode; the suspended state won't be restored"))
        } else if bundle.hasSavedState {
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
    /// Windows 收不到 VZ 的电源键事件，macOS 收到只弹关机确认框：改在后台经客户机代理或 SSH 关机，
    /// 都不行才按电源键。
    public func requestStop() throws {
        guard virtualMachine.canRequestStop else { throw MacVMError.notRunning(bundle.name) }
        switch config.os {
        case .linux:
            try pressPowerButton()
        case .windows:
            guard config.networks.first?.macAddress != nil else { return try pressPowerButton() }
            let bundle = bundle, config = config
            let agent = config.guestAgent, user = config.guestUser
            Task.detached { [weak self] in
                if let ip = GuestAddress.current(bundle, config) {
                    if agent, Self.callAgent(bundle, ip, .shutdown(reboot: false)) { return }
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

    /// 先经 SSH 用包内保存的客户机密码 sudo 立即关机；不行再经 vsock 请代理关机。返回客户机是否接受。
    /// 代理以登录用户身份运行，只能像用户点「关机」那样请求，其他 App 可以拦下，所以排在后面。
    private func shutdownMacOSGuest() async -> Bool {
        if let user = config.guestUser, let ip = guestIP, let password = GuestCredentials.password(for: bundle),
           await Task.detached(operation: { [bundle] in
               Self.sshSudoShutdown(user: user, ip: ip, password: password, knownHosts: bundle.knownHostsURL)
           }).value {
            return true
        }
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
        return false
    }

    /// 登录先试 macvm 专用密钥，客户机没装公钥时用 `password`；sudo 认证通过后先输出 `sshShutdownMarker`，
    /// 再在客户机后台立即关机。返回是否收到标记：关机会断开连接，ssh 的退出码不能说明 sudo 是否成功。
    /// 主机密钥按 `knownHosts` 固定：桥接时客户机 IP 在真实局域网上，不校验的话冒充该 IP 的机器就能收到密码。
    nonisolated private static func sshSudoShutdown(user: String, ip: String, password: String, knownHosts: URL) -> Bool {
        guard let askpass = try? GuestSSH.makeAskpass() else { return false }
        defer { try? FileManager.default.removeItem(at: askpass) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        let remote = "sudo -S -p '' /bin/sh -c 'echo \(sshShutdownMarker); nohup /sbin/shutdown -h now >/dev/null 2>&1 &'"
        process.arguments = ["-q", "-T"] + SSHConfig.pinnedKeyArguments(knownHosts: knownHosts)
            + ["-o", "PreferredAuthentications=publickey,keyboard-interactive,password", "-o", "NumberOfPasswordPrompts=1",
               "-o", "ConnectTimeout=10", "\(user)@\(ip)", remote]
        process.environment = GuestSSH.askpassEnvironment(askpass, password: password)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + sshShutdownTimeout) == .timedOut {
            process.terminate()
            exited.wait()
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.contains(sshShutdownMarker)
    }

    nonisolated private static let sshShutdownMarker = "macvm-shutdown-accepted"
    nonisolated private static let sshShutdownTimeout: TimeInterval = 20

    private func pressPowerButton() throws {
        do { try virtualMachine.requestStop() } catch {
            throw MacVMError.engine(String(l10n: "Couldn't request a shutdown: \(error.localizedDescription)"))
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

    /// 经网络直连 Windows 客户机的代理发一个请求，返回是否成功。
    nonisolated private static func callAgent(_ bundle: VMBundle, _ ip: String, _ request: AgentProtocol.Request, timeout: Int = 3) -> Bool {
        guard let socket = try? GuestConnection.direct(ip, port: UInt16(AgentProtocol.port), bundle: bundle) else { return false }
        return AgentClient.call(request, over: socket, timeout: timeout)
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
    /// 保存或断电失败时删掉状态文件，原先在运行的恢复运行：虚拟机还会继续写磁盘，留下的状态已不可用。
    public func suspend() async throws {
        guard canSuspend else {
            throw MacVMError.unsupported(String(l10n: "This virtual machine's configuration doesn't support suspending"))
        }
        if let saved = try? bundle.loadConfig(), saved.audioDiffers(from: config) { throw VMConfig.audioChangedSinceBootError }
        try requireNoAttachedImages()
        try markShareDevice()
        let wasRunning = virtualMachine.state == .running
        if wasRunning { try await pause() }
        let url = bundle.savedStateURL
        do {
            try await virtualMachine.saveMachineStateTo(url: url)
            try await virtualMachine.stop()
        } catch {
            try? FileManager.default.removeItem(at: url)
            if wasRunning, virtualMachine.canResume { try? await virtualMachine.resume() }
            throw error
        }
        finish(.suspended)
    }

    /// 在写挂起状态之前记下这次开机有没有共享目录设备，记不下就不挂起：恢复时 `ConfigBuilder` 靠它组装同样的设备。
    private func markShareDevice() throws {
        let marker = bundle.savedStateShareDeviceURL
        do {
            if automountShareDevice != nil {
                try Data().write(to: marker)
            } else if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
        } catch {
            throw MacVMError.io(String(l10n: "Couldn't write \(marker.path): \(error.localizedDescription)"))
        }
    }

    /// 连接客户机内监听的 vsock 端口。返回的连接须保持引用直到用完。
    public func connectToGuest(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw MacVMError.unsupported(String(l10n: "The virtual machine has no vsock device"))
        }
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<VZVirtioSocketConnection>, any Error>) in
                device.connect(toPort: port) { c.resume(with: $0.map(Unchecked.init)) }
            }.value
        } catch {
            throw MacVMError.notRunning(String(l10n: "Nothing is listening on guest vsock port \(port)"))
        }
    }

    /// VZ 没有截取画面的接口，画面只存在于 `VZVirtualMachineView` 里。
    public func screenshot(to url: URL) async throws {
        throw MacVMError.unsupported(String(l10n: "The VZ engine doesn't support screenshots"))
    }

    /// Windows 没有 VZ 能用的 vsock 驱动，改经网络连客户机 IP 上的同号 TCP 端口。
    public func openGuestChannel(port: UInt32) async throws -> GuestChannel {
        if config.os == .windows {
            guard let ip = guestIP else {
                throw MacVMError.io(String(l10n: "\(bundle.name)'s IP address isn't known yet"))
            }
            let bundle = bundle
            let fd = try await Task.detached { try GuestConnection.direct(ip, port: UInt16(port), bundle: bundle).duplicateDescriptor() }.value
            return GuestChannel(fileDescriptor: fd, close: { Darwin.close(fd) })
        }
        let connection = Unchecked(value: try await connectToGuest(port: port))
        return GuestChannel(fileDescriptor: connection.value.fileDescriptor, close: { connection.value.close() })
    }

    /// 改变显示输出尺寸。
    public func resizeDisplay(width: Int, height: Int) throws {
        guard config.os != .windows else { throw WindowsSupport.fixedDisplayError }
        guard let display = virtualMachine.graphicsDevices.first?.displays.first else { throw MacVMError.unsupported(String(l10n: "\(bundle.name) has no display device")) }
        do { try display.reconfigure(sizeInPixels: CGSize(width: width, height: height)) } catch {
            throw MacVMError.engine(String(l10n: "Couldn't resize the display: \(error.localizedDescription)"))
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
        screenLockSync?.cancel()
        staticAddressSync?.cancel()
        bridgedAddressWatch?.cancel()
        BridgedAddress.clear(bundle)
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
