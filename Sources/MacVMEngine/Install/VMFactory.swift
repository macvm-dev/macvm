public import Foundation
public import MacVMModel
@preconcurrency import Virtualization

/// 创建 EFI 客户机（Linux、Windows）的包：磁盘、机器标识、EFI 变量存储、配置。
/// 指定云镜像时磁盘从镜像缓存克隆，并附带 cloud-init 种子盘注入用户与 SSH 公钥。
/// macOS 客户机的包由 `MacOSInstaller` 创建，因为硬件型号取决于安装镜像。
public enum VMFactory {
    public struct Options: Sendable {
        public var name: String
        public var os: GuestOS
        public var cpuCount: Int
        public var memorySize: UInt64
        public var diskSize: UInt64
        public var installMedia: [String]
        public var network: NetworkConfig
        public var shares: [ShareConfig]
        public var rosetta: Bool
        public var serialConsole: Bool
        public var image: LinuxImage?
        /// 下载该桌面版安装 ISO 作为安装介质，排在 `installMedia` 前面。
        public var desktop: LinuxDesktop?
        /// 云镜像里创建的登录用户。
        public var user: String
        /// 云镜像里登录用户的密码，存进包内 `guest-password`；nil 时只能用 SSH 密钥登录。
        public var password: String?
        public var showProgress: Bool
        /// 默认云镜像为 headless（可挂起），安装介质方式带键鼠。
        public var headless: Bool?
        /// 写进 `VMBundle.creationMarkerURL`。
        public var creationToken: String?

        public init(name: String, os: GuestOS, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                    installMedia: [String] = [], network: NetworkConfig = .init(), shares: [ShareConfig] = [],
                    rosetta: Bool = false, serialConsole: Bool = false, image: LinuxImage? = nil, desktop: LinuxDesktop? = nil,
                    user: String = NSUserName(), password: String? = nil, showProgress: Bool = false, headless: Bool? = nil,
                    creationToken: String? = nil) {
            self.name = name
            self.os = os
            self.cpuCount = cpuCount ?? HostInfo.defaultCPUCount()
            self.memorySize = memorySize ?? HostInfo.defaultMemorySize()
            self.diskSize = diskSize ?? HostInfo.defaultDiskSize(for: os)
            self.installMedia = installMedia
            self.network = network
            self.shares = shares
            self.rosetta = rosetta
            self.serialConsole = serialConsole
            self.image = image
            self.desktop = desktop
            self.user = user
            self.password = password
            self.showProgress = showProgress
            self.headless = headless
            self.creationToken = creationToken
        }
    }

    public static func createEFIGuest(_ options: Options, in library: VMLibrary = .default) async throws -> VMBundle {
        precondition(options.os.usesEFI)
        if options.os == .windows, !WindowsSupport.isAvailable {
            throw MacVMError.unsupported("当前 macOS 不支持运行 Windows 客户机")
        }
        if options.image != nil || options.desktop != nil, options.os != .linux {
            throw MacVMError.invalidConfig("云镜像与桌面版只用于 Linux 客户机")
        }
        if options.image != nil, options.desktop != nil {
            throw MacVMError.invalidConfig("云镜像与桌面版只能选一个")
        }
        try ensureNameAvailable(options.name, in: library)
        // 先下载镜像再建包，下载中断不会留下半成品虚拟机。
        var imageDisk: URL?
        if let image = options.image {
            imageDisk = try await ImageCache.disk(for: image, showProgress: options.showProgress)
        }
        var installMedia = options.installMedia
        if let desktop = options.desktop {
            installMedia.insert(try await ISOCache.iso(for: desktop, showProgress: options.showProgress).path, at: 0)
        }

        var network = options.network
        if network.macAddress == nil { network.macAddress = NetworkAttachments.randomMACAddress() }

        return try await withNewBundle(named: options.name, in: library, creationToken: options.creationToken) { bundle in
            var hasAgent = false
            var disks = [DiskConfig(path: bundle.diskURL.lastPathComponent)]
            if let imageDisk {
                try Clone.file(from: imageDisk, to: bundle.diskURL)
                if try DiskImage.allocatedSize(at: bundle.diskURL).logical < options.diskSize {
                    try DiskImage.grow(at: bundle.diskURL, to: options.diskSize)
                }
                let seed = CloudInit.Options(hostname: options.name, user: options.user, password: options.password,
                                             sshPublicKey: try await SSHKeys.ensurePublicKey(),
                                             macAddress: network.macAddress!, shares: options.shares, rosetta: options.rosetta)
                try await CloudInit.writeSeed(seed, instanceID: UUID().uuidString, in: bundle)
                if let password = options.password { try GuestCredentials.storePassword(password, in: bundle) }
                hasAgent = seed.agentBinary != nil
                disks.append(DiskConfig(path: CloudInit.seedFileName, readOnly: true))
            } else {
                try DiskImage.createSparse(at: bundle.diskURL, size: options.diskSize)
            }
            try MachineIdentity.createGeneric(in: bundle)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL)

            let media = try installMedia.map { path -> String in
                let url = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else { throw MacVMError.invalidConfig("安装介质不存在：\(url.path)") }
                return url.path
            }
            let config = VMConfig(
                name: options.name,
                os: options.os,
                cpuCount: options.cpuCount,
                memorySize: options.memorySize,
                disks: disks,
                networks: [network],
                shares: options.shares,
                audio: options.os != .windows,
                rosetta: options.rosetta,
                installMedia: media,
                headless: options.headless ?? (options.image != nil),
                guestUser: options.image != nil ? options.user : nil,
                guestAgent: hasAgent,
                serialConsole: options.serialConsole
            )
            try bundle.saveConfig(config)
            try await RunnerFactory.prepare(bundle)
            // 立即组装一次，让磁盘、网络、共享目录等配置错误在创建时就暴露。
            _ = try ConfigBuilder(bundle: bundle, config: config).build(validate: Entitlements.has(Entitlements.virtualization))
            return bundle
        }
    }

    /// 名称合法且未被占用。要在下载等耗时准备之前先查，免得白等一场才报错。
    static func ensureNameAvailable(_ name: String, in library: VMLibrary) throws {
        try VMLibrary.validate(name: name)
        if FileManager.default.fileExists(atPath: library.bundleURL(named: name).path) { throw MacVMError.alreadyExists(name) }
    }

    /// 建一个空包交给 `body` 填充；`body` 抛错时删掉整个包，不留半成品。
    static func withNewBundle<T>(named name: String, in library: VMLibrary, creationToken: String? = nil,
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ body: (VMBundle) async throws -> T) async throws -> T {
        let bundle = try prepareEmptyBundle(named: name, in: library)
        do {
            if let creationToken {
                do { try Data(creationToken.utf8).write(to: bundle.creationMarkerURL) } catch {
                    throw MacVMError.io("写入 \(bundle.creationMarkerURL.path) 失败：\(error.localizedDescription)")
                }
            }
            return try await body(bundle)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    private static func prepareEmptyBundle(named name: String, in library: VMLibrary) throws -> VMBundle {
        try VMLibrary.validate(name: name)
        try library.ensureRoot()
        let url = library.bundleURL(named: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw MacVMError.alreadyExists(name)
        } catch {
            throw MacVMError.io("创建 \(url.path) 失败：\(error.localizedDescription)")
        }
        return VMBundle(url: url)
    }

    public static func delete(_ bundle: VMBundle) throws {
        if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(bundle.name) }
        do { try FileManager.default.removeItem(at: bundle.url) } catch {
            throw MacVMError.io("删除 \(bundle.url.path) 失败：\(error.localizedDescription)")
        }
    }
}
