public import Foundation
public import MacVMModel
@preconcurrency import Virtualization

/// 从 IPSW 创建并安装 macOS 客户机。
@MainActor
public enum MacOSInstaller {
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

        public init(name: String, source: Source, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                    user: String = NSUserName(), password: String? = nil, display: DisplayConfig = .init(), showProgress: Bool = false) {
            self.name = name
            self.source = source
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
            self.user = user
            self.password = password
            self.display = display
            self.showProgress = showProgress
        }
    }

    public enum Phase: Sendable {
        case downloading
        case installing(Double)
    }

    public static func install(_ options: Options, in library: VMLibrary = .default, progress: @escaping @MainActor (Phase) -> Void = { _ in }) async throws -> VMBundle {
        guard VZVirtualMachine.isSupported else { throw MacVMError.unsupported("本机不支持虚拟化") }
        try VMLibrary.validate(name: options.name)
        if FileManager.default.fileExists(atPath: library.bundleURL(named: options.name).path) {
            throw MacVMError.alreadyExists(options.name)
        }

        let ipsw: URL
        switch options.source {
        case .file(let url): ipsw = url
        case .latest:
            progress(.downloading)
            ipsw = try await downloadLatest(showProgress: options.showProgress)
        }

        let image = try await loadImage(ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MacVMError.unsupported("主机 macOS 版本过旧，无法安装 \(image.operatingSystemVersion.label)（\(image.buildVersion)）")
        }

        let bundle = try VMFactory.prepareEmptyBundle(named: options.name, in: library)
        do {
            try DiskImage.createSparse(at: bundle.diskURL, size: options.diskSize ?? HostInfo.defaultDiskSize(for: .macOS))
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: requirements.hardwareModel, options: [])
            try MachineIdentity.saveHardwareModel(requirements.hardwareModel, in: bundle)
            try MachineIdentity.createMac(in: bundle)

            let config = VMConfig(
                name: options.name, os: .macOS,
                cpuCount: max(options.cpuCount ?? HostInfo.defaultCPUCount(), requirements.minimumSupportedCPUCount),
                memorySize: max(options.memorySize ?? HostInfo.defaultMemorySize(for: .macOS), requirements.minimumSupportedMemorySize),
                disks: [DiskConfig(path: bundle.diskURL.lastPathComponent)],
                display: options.display,
                networks: [NetworkConfig(macAddress: NetworkAttachments.randomMACAddress())],
                guestUser: options.user
            )
            try bundle.saveConfig(config)
            try MacOSProvisioning.schedule(.init(user: options.user, password: options.password ?? MacOSProvisioning.randomPassword()), in: bundle)

            let vz = try ConfigBuilder(bundle: bundle, config: config).build()
            let vm = VZVirtualMachine(configuration: vz)
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress(.installing(fraction)) }
            }
            defer { observation.invalidate() }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                installer.install { c.resume(with: $0) }
            }
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw MacVMError.engine("安装 macOS 失败：\(VMRunner.describe(error))")
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
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "MacVM/ipsw", directoryHint: .isDirectory)
    }

    private static func downloadLatest(showProgress: Bool) async throws -> URL {
        let (url, build) = try await latestRestoreImage()
        try FileManager.default.createDirectory(at: ipswCache, withIntermediateDirectories: true)
        let target = ipswCache.appending(path: "\(build).ipsw")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let partial = ipswCache.appending(path: "\(build).ipsw.part")
        try await Subprocess.run("/usr/bin/curl", ["-fL", "--retry", "3", "-C", "-", showProgress ? "--progress-bar" : "-sS", "-o", partial.path, url.absoluteString],
                                 passthroughStderr: showProgress)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    private static func loadImage(_ url: URL) async throws -> VZMacOSRestoreImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MacVMError.invalidConfig("IPSW 不存在：\(url.path)") }
        do {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<VZMacOSRestoreImage>, any Error>) in
                VZMacOSRestoreImage.load(from: url) { c.resume(with: $0.map(Unchecked.init)) }
            }.value
        } catch {
            throw MacVMError.invalidConfig("无法读取 IPSW：\(error.localizedDescription)")
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
