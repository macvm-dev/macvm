public import Foundation
public import MacVMModel
@preconcurrency import Virtualization

/// 从 IPSW 创建并安装 macOS 客户机。
@MainActor
public enum MacOSInstaller {
    /// 刚装好的虚拟机首次开机：安装用的虚拟机在安装结束后还要一会儿才放开辅助储存，这期间开机会失败，
    /// 隔 `firstBootRetryInterval` 重试 `start`，共 `firstBootAttempts` 次，抛出最后一次的错误；任务取消后不再重试。
    /// `MacVMError.timeout` 不重试：等启动超时时虚拟机可能还在启动，再开一次只会撞上包锁；`alreadyRunning` 也不重试。
    public static func firstBoot(isolation: isolated (any Actor)? = #isolation,
                                 _ start: () async throws -> Void) async throws {
        for attempt in 1... {
            do {
                return try await start()
            } catch where attempt < firstBootAttempts && !Task.isCancelled && isRetryable(error) {
                try await Task.sleep(for: firstBootRetryInterval)
            }
        }
    }

    nonisolated private static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case MacVMError.timeout, MacVMError.alreadyRunning: false
        default: true
        }
    }

    nonisolated static let firstBootAttempts = 10
    nonisolated static let firstBootRetryInterval: Duration = .seconds(2)

    public enum Source: Sendable {
        /// 本机支持的最新版本，从 Apple 下载并缓存。
        case latest
        case file(URL)
    }

    public struct Options: Sendable {
        public var name: String
        public var source: Source
        public var cpuCount: Int?
        public var memorySize: UInt64?
        public var diskSize: UInt64?
        public var user: String
        /// nil 时生成随机密码。
        public var password: String?
        public var display: DisplayConfig
        public var showProgress: Bool
        /// 写进 `VMBundle.creationMarkerURL`。
        public var creationToken: String?

        public init(name: String, source: Source, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                    user: String = NSUserName(), password: String? = nil, display: DisplayConfig = .init(), showProgress: Bool = false,
                    creationToken: String? = nil) {
            self.name = name
            self.source = source
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
            self.user = user
            self.password = password
            self.display = display
            self.showProgress = showProgress
            self.creationToken = creationToken
        }
    }

    public enum Phase: Sendable {
        case downloading
        case installing(Double)
    }

    public static func install(_ options: Options, in library: VMLibrary = .default, progress: @escaping @MainActor (Phase) -> Void = { _ in }) async throws -> VMBundle {
        guard VZVirtualMachine.isSupported else { throw MacVMError.unsupported(String(l10n: "This Mac doesn't support virtualization")) }
        try VMFactory.ensureNameAvailable(options.name, in: library)

        let ipsw: URL
        switch options.source {
        case .file(let url): ipsw = url
        case .latest:
            progress(.downloading)
            ipsw = try await downloadLatest(showProgress: options.showProgress)
        }

        let image = try await loadImage(ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MacVMError.unsupported(String(l10n: "macOS on this Mac is too old to install \(image.operatingSystemVersion.label) (\(image.buildVersion))"))
        }

        return try await VMFactory.withNewBundle(named: options.name, in: library, creationToken: options.creationToken) { bundle in
            do {
                try DiskImage.createSparse(at: bundle.diskURL, size: options.diskSize ?? HostInfo.defaultDiskSize(for: .macOS))
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: requirements.hardwareModel, options: [])
                try MachineIdentity.saveHardwareModel(requirements.hardwareModel, in: bundle)
                try MachineIdentity.createMac(in: bundle)

                let config = VMConfig(
                    name: options.name, os: .macOS,
                    cpuCount: max(options.cpuCount ?? HostInfo.defaultCPUCount(), requirements.minimumSupportedCPUCount),
                    memorySize: max(options.memorySize ?? HostInfo.defaultMemorySize(), requirements.minimumSupportedMemorySize),
                    disks: [DiskConfig(path: bundle.diskURL.lastPathComponent)],
                    display: options.display,
                    networks: [NetworkConfig(macAddress: NetworkAttachments.randomMACAddress())],
                    guestUser: options.user
                )
                try bundle.saveConfig(config)
                try MacOSProvisioning.schedule(.init(user: options.user, password: options.password ?? GuestCredentials.randomPassword()), in: bundle)

                let vz = try ConfigBuilder(bundle: bundle, config: config).build()
                let vm = VZVirtualMachine(configuration: vz)
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                    let fraction = p.fractionCompleted
                    Task { @MainActor in progress(.installing(fraction)) }
                }
                defer { observation.invalidate() }
                let installProgress = installer.progress
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                        installer.install { c.resume(with: $0) }
                    }
                } onCancel: {
                    installProgress.cancel()
                }
                return bundle
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // 只把 Virtualization 的错误归为 engine；准备包内文件时已分好类的错误原样抛出。
                if error is MacVMError { throw error }
                throw MacVMError.engine(String(l10n: "Couldn't install macOS: \(describeEngineError(error))"))
            }
        }
    }

    /// 本机支持的最新 IPSW 的下载地址与构建号。
    public static func latestRestoreImage() async throws -> (url: URL, build: String) {
        let image = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<VZMacOSRestoreImage>, any Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { c.resume(with: $0.map(Unchecked.init)) }
        }.value
        return (image.url, image.buildVersion)
    }

    static var ipswCache: URL {
        DownloadCache.root.appending(path: "ipsw", directoryHint: .isDirectory)
    }

    private static func downloadLatest(showProgress: Bool) async throws -> URL {
        let (url, build) = try await latestRestoreImage()
        // 只取一次：下载期间设置里的目录可能被改，中间文件得留在同一处。
        let ipswCache = ipswCache
        let target = ipswCache.appending(path: "\(build).ipsw")
        return try await Download.cached(target, from: url, via: ipswCache.appending(path: "\(build).ipsw.part"), showProgress: showProgress)
    }

    private static func loadImage(_ url: URL) async throws -> VZMacOSRestoreImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MacVMError.invalidConfig(String(l10n: "IPSW not found: \(url.path)")) }
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<VZMacOSRestoreImage>, any Error>) in
                VZMacOSRestoreImage.load(from: url) { c.resume(with: $0.map(Unchecked.init)) }
            }.value
        } catch {
            throw MacVMError.invalidConfig(String(l10n: "Couldn't read the IPSW: \(error.localizedDescription)"))
        }
    }
}

/// 把 VZ 回调交出的、只在主线程上使用的非 Sendable 对象带过续体边界。
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

extension OperatingSystemVersion {
    var label: String { "macOS \(majorVersion).\(minorVersion)\(patchVersion > 0 ? ".\(patchVersion)" : "")" }
}
