public import Foundation
public import MacVMModel

public enum MachineStopReason: Sendable, Equatable {
    case guestShutdown
    case suspended
    case forced
    case error(String)

    public var label: String {
        switch self {
        case .guestShutdown: "guest_shutdown"
        case .suspended: "suspended"
        case .forced: "forced"
        case .error: "error"
        }
    }
}

public enum MachineStartOutcome: Sendable {
    case coldBoot
    case restored
    /// 挂起状态没有用上（与当前配置或主机版本不符，或以恢复模式启动），已丢弃并冷启动。
    case restoreFailed(String)
}

/// 运行器的停止信号：只在首次 `fire` 时记下原因、释放包锁、回调 `onStop` 并唤醒所有等待者。
/// 也维护包内 `VMBundle.poweredOffMarkerURL`：开机成功时删掉，关机或断电停下时写入。
@MainActor
final class StopLatch {
    private(set) var reason: MachineStopReason?
    var onStop: ((MachineStopReason) -> Void)?
    private let bundle: VMBundle
    private let lock: ProcessLock
    private var waiters: [CheckedContinuation<MachineStopReason, Never>] = []

    init(bundle: VMBundle, lock: ProcessLock) {
        self.bundle = bundle
        self.lock = lock
    }

    /// 运行器开机成功后调用。
    func started() {
        try? FileManager.default.removeItem(at: bundle.poweredOffMarkerURL)
    }

    func fire(_ reason: MachineStopReason) {
        guard self.reason == nil else { return }
        self.reason = reason
        if reason == .guestShutdown || reason == .forced {
            FileManager.default.createFile(atPath: bundle.poweredOffMarkerURL.path, contents: nil)
        }
        lock.release()
        onStop?(reason)
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: reason) }
    }

    func wait() async -> MachineStopReason {
        if let reason { return reason }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// 把 Virtualization 等框架的 NSError 连同 underlying error 里的具体原因展开成一行。
func describeEngineError(_ error: any Error) -> String {
    let ns = error as NSError
    var parts = ["\(ns.domain)#\(ns.code) \(ns.localizedDescription)"]
    if let reason = ns.localizedFailureReason { parts.append(reason) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append(describeEngineError(underlying)) }
    return parts.joined(separator: String(l10n: "; "))
}

/// 到客户机内某个端口的双向字节通道；用完调用 `close`。
public struct GuestChannel: Sendable {
    public let fileDescriptor: Int32
    public let close: @Sendable () -> Void
}

/// 一台运行中的虚拟机，与具体引擎无关。持有者负责包内 `run.lock`。
@MainActor
public protocol MachineRunner: AnyObject, Sendable {
    var bundle: VMBundle { get }
    var config: VMConfig { get }
    /// 与 `VZVirtualMachine.State` 的标签同一套取值：running、paused、stopped、starting 等。
    var stateLabel: String { get }
    var canSuspend: Bool { get }
    var onStop: ((MachineStopReason) -> Void)? { get set }
    /// 运行中能否用 `updateShares` 改共享目录。
    var supportsLiveShares: Bool { get }

    @discardableResult
    func start(recovery: Bool) async throws -> MachineStartOutcome
    func requestStop() throws
    func forceStop() async throws
    func pause() async throws
    func resume() async throws
    func suspend() async throws
    func waitUntilStopped() async -> MachineStopReason
    func openGuestChannel(port: UInt32) async throws -> GuestChannel
    func screenshot(to url: URL) async throws
    func resizeDisplay(width: Int, height: Int) throws
    func updateShares(_ shares: [ShareConfig]) throws
    /// 运行中能否用 `attachImage` 热插磁盘映像。
    var supportsImageHotPlug: Bool { get }
    var attachedImages: [AttachedImage] { get }
    /// 把磁盘映像作为 U 盘接到客户机的 USB 控制器上。
    func attachImage(_ url: URL, readOnly: Bool) async throws -> AttachedImage
    /// 拔下 `attachImage` 接入的映像；客户机没先推出时，它还没写回的数据会丢失。
    func ejectImage(_ id: UUID) async throws
}

extension MachineRunner {
    @discardableResult
    public func start() async throws -> MachineStartOutcome { try await start(recovery: false) }
}

public enum RunnerFactory {
    /// 组装 VZ 配置之前要做的异步准备，只有 VZ 引擎的 Windows 客户机需要。
    static func prepare(_ bundle: VMBundle) async throws {
        let config = try bundle.loadConfig()
        if config.os == .windows, config.engine == .vz {
            try await WindowsSupport.prepareForVZ(bundle)
        }
    }

    /// 已在运行时先报 `alreadyRunning`：`prepare` 会重建包内文件，不能在运行中的虚拟机上做；包锁要到运行器建好时才取得。
    @MainActor
    public static func make(_ bundle: VMBundle, console: ConfigBuilder.Console = .none, display: Bool = false) async throws -> any MachineRunner {
        if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(bundle.name) }
        try await prepare(bundle)
        return switch try bundle.loadConfig().engine {
        case .vz: try VZRunner(bundle: bundle, console: console)
        case .qemu: try QEMURunner(bundle: bundle, display: display)
        }
    }
}
