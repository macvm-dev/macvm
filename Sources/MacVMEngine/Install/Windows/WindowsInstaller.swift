public import Foundation
public import MacVMModel

/// 用 QEMU 引擎从微软原版 ISO 无人值守部署 Windows 11 ARM64。
///
/// 不走 Windows 安装程序：它只肯从启动用的光驱读 install.wim，而 QEMU 下 EDK2 能启动的光驱只有模拟 USB，
/// 读取慢到整个安装要一个多小时。改为光盘只负责启动 WinPE，WinPE 运行安装盘上的部署脚本，
/// 从 NVMe 数据盘（exFAT，含 install.wim 与驱动）用 DISM 直接部署，几分钟完成。
/// 安装盘 `windows-setup.img`（FAT32）放两阶段应答文件与脚本；装完后两块盘都会删除。
public enum WindowsInstaller {
    public static let setupImageName = "windows-setup.img"
    public static let dataImageName = "windows-data.img"
    static let virtioWinURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
    static let drivers = ["NetKVM", "viostor", "vioscsi", "viogpudo", "viosock", "viofs", "Balloon", "vioserial", "viorng", "vioinput"]

    public struct Options: Sendable {
        public var name: String
        public var iso: URL
        public var virtioWin: URL?
        public var cpuCount: Int?
        public var memorySize: UInt64?
        public var diskSize: UInt64?
        public var user: String
        public var password: String?
        /// 装好后用它激活；不写进虚拟机配置。省略时系统保持未激活。
        public var productKey: String?
        public var showProgress: Bool

        public init(name: String, iso: URL, virtioWin: URL? = nil, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                    user: String = NSUserName(), password: String? = nil, productKey: String? = nil, showProgress: Bool = false) {
            self.name = name
            self.iso = iso
            self.virtioWin = virtioWin
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
            self.user = user
            self.password = password
            self.productKey = productKey
            self.showProgress = showProgress
        }
    }

    /// 产品密钥统一成大写、以连字符分成五组各五个字符；格式不对时报错。
    public static func normalizeProductKey(_ key: String) throws -> String {
        let characters = key.uppercased().filter { $0.isLetter || $0.isNumber }
        guard characters.count == 25, characters.allSatisfy({ $0.isASCII }) else {
            throw MacVMError.invalidConfig("产品密钥应为 25 个字母或数字（XXXXX-XXXXX-XXXXX-XXXXX-XXXXX）")
        }
        return stride(from: 0, to: 25, by: 5).map { start in
            String(characters[characters.index(characters.startIndex, offsetBy: start)..<characters.index(characters.startIndex, offsetBy: start + 5)])
        }.joined(separator: "-")
    }

    /// 建好包与安装盘；之后 `start` 即开始安装，完成与否看 `isSetupComplete`。
    public static func create(_ options: Options, in library: VMLibrary = .default) async throws -> VMBundle {
        let qemu = try QEMUInstallation.require()
        try VMFactory.ensureNameAvailable(options.name, in: library)
        guard FileManager.default.fileExists(atPath: options.iso.path) else { throw MacVMError.invalidConfig("ISO 不存在：\(options.iso.path)") }

        let productKey = try options.productKey.map(normalizeProductKey)
        let locale = try await readLocale(iso: options.iso)
        var virtioWin = options.virtioWin
        if virtioWin == nil { virtioWin = try await cachedVirtioWin(showProgress: options.showProgress) }
        let password = options.password ?? GuestCredentials.randomPassword()
        var unattend = WindowsUnattend.Options(
            computerName: String(options.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(15)),
            user: options.user, password: password, locale: locale,
            sshPublicKey: try await SSHKeys.ensurePublicKey(),
            installAgent: AgentInstaller.binary(for: .windows) != nil,
            productKey: productKey
        )
        // 驱动由代理装，没有代理就不放。
        unattend.installGPUDriver = unattend.installAgent && WindowsGPUDriver.package(qemu) != nil

        return try await VMFactory.withNewBundle(named: options.name, in: library) { bundle in
            try await buildSetupImage(unattend, gpuDriver: unattend.installGPUDriver ? WindowsGPUDriver.package(qemu) : nil,
                                      to: bundle.url.appending(path: setupImageName))
            try await buildDataImage(iso: options.iso, virtioWin: virtioWin!, to: bundle.url.appending(path: dataImageName))
            try DiskImage.createSparse(at: bundle.diskURL, size: options.diskSize ?? HostInfo.defaultDiskSize(for: .windows))
            try MachineIdentity.createGeneric(in: bundle)
            try qemu.ensureVars(for: bundle)
            try GuestCredentials.storePassword(password, in: bundle)
            let config = VMConfig(
                name: options.name, os: .windows, engine: .qemu,
                cpuCount: options.cpuCount ?? HostInfo.defaultCPUCount(),
                memorySize: options.memorySize ?? HostInfo.defaultMemorySize(),
                disks: [DiskConfig(path: bundle.diskURL.lastPathComponent, bus: .nvme), DiskConfig(path: dataImageName, bus: .nvme)],
                networks: [NetworkConfig(macAddress: NetworkAttachments.randomMACAddress())],
                installMedia: [options.iso.path, setupImageName],
                guestUser: options.user,
                guestAgent: unattend.installAgent,
                graphicsAcceleration: unattend.installGPUDriver
            )
            try bundle.saveConfig(config)
            return bundle
        }
    }

    /// 在已开机安装的 `bundle` 上等首次登录脚本写下完成标记，然后经 `requestStop` 请客户机关机，
    /// 停下后 `finishSetup`。返回 false 表示客户机在 `stopTimeout` 秒内没有关机，安装介质仍挂着。
    public static func completeSetup(_ bundle: VMBundle, macvmPath: String, stopTimeout: TimeInterval = 180,
                                     isolation: isolated (any Actor)? = #isolation,
                                     requestStop: () async throws -> Void) async throws -> Bool {
        try await waitUntilSetupComplete(bundle, macvmPath: macvmPath)
        try await requestStop()
        guard try await VMStatus.waitUntilStopped(bundle, timeout: stopTimeout) else { return false }
        try finishSetup(bundle)
        return true
    }

    /// 轮询直到首次登录脚本写下完成标记。
    private static func waitUntilSetupComplete(_ bundle: VMBundle, macvmPath: String, timeout: TimeInterval = 3 * 3600) async throws {
        let config = try bundle.loadConfig()
        guard let user = config.guestUser else { throw MacVMError.invalidConfig("缺少客户机用户") }
        let proxy = SSHConfig.proxyCommand(macvmPath: macvmPath, name: bundle.name, flags: ["--timeout", "10"])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if BundleLock.holder(of: bundle) == nil { throw MacVMError.engine("安装过程中虚拟机意外停止，日志：\(bundle.logURL.path)") }
            let output = try? await Subprocess.run("/usr/bin/ssh", ["-q", "-T"] + SSHConfig.keyArguments(proxyCommand: proxy) + [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
                "\(user)@\(bundle.name)", "Test-Path \(WindowsUnattend.doneMarker)",
            ])
            if output?.contains("True") == true { return }
            guard Date() < deadline else { throw MacVMError.timeout("Windows 安装超时") }
            try await Task.sleep(for: .seconds(15))
        }
    }

    /// 安装完成后卸下安装介质与数据盘并删除它们（安装盘含明文密码）。
    static func finishSetup(_ bundle: VMBundle) throws {
        var config = try bundle.loadConfig()
        config.installMedia = []
        config.disks.removeAll { $0.path == dataImageName }
        try bundle.saveConfig(config)
        for name in [setupImageName, dataImageName] {
            try? FileManager.default.removeItem(at: bundle.url.appending(path: name))
        }
    }

    // MARK: - 安装盘

    static func buildSetupImage(_ o: WindowsUnattend.Options, gpuDriver: URL? = nil, to output: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "macvm-winsetup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try WindowsUnattend.autounattend().write(to: staging.appending(path: "autounattend.xml"), atomically: true, encoding: .utf8)
        try WindowsUnattend.unattend(o).write(to: staging.appending(path: "unattend.xml"), atomically: true, encoding: .utf8)
        try WindowsUnattend.installScript().write(to: staging.appending(path: WindowsUnattend.installScriptName), atomically: true, encoding: .ascii)
        try WindowsUnattend.setupScript(o).write(to: staging.appending(path: "setup.ps1"), atomically: true, encoding: .utf8)
        if o.installAgent, let agent = AgentInstaller.binary(for: .windows) {
            try FileManager.default.copyItem(at: agent, to: staging.appending(path: WindowsUnattend.agentFileName))
        }
        if let gpuDriver {
            try await WindowsGPUDriver.extract(gpuDriver, to: staging.appending(path: WindowsUnattend.gpuDriverFolder))
        }

        try await DiskImage.createFAT(from: staging, to: output, size: "64m", volumeName: WindowsUnattend.volumeLabel, fat32: true)
    }

    /// GPT + exFAT 的稀疏 raw 镜像，放 ISO 里的 install.wim 与 virtio-win 的 ARM64 驱动。
    /// exFAT 没有 FAT32 的 4 GB 单文件上限，Windows 又有内置驱动。
    static func buildDataImage(iso: URL, virtioWin: URL, to output: URL) async throws {
        let wimSize = try await DiskMount.withMounted(iso) { root -> UInt64 in
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appending(path: "sources/install.wim").path)
            return (attrs[.size] as? UInt64) ?? 0
        }
        guard wimSize > 0 else { throw MacVMError.invalidConfig("ISO 中没有 sources/install.wim（不支持 install.esd 格式的镜像）") }
        try DiskImage.createSparse(at: output, size: wimSize + (1 << 30))

        try await DiskMount.withAttachedRaw(output) { device in
            try await Subprocess.run("/usr/sbin/diskutil", ["partitionDisk", device, "GPT", "ExFAT", WindowsUnattend.dataVolumeLabel, "100%"])
            let volume = try await DiskMount.mountPoint(ofPartitionNamed: WindowsUnattend.dataVolumeLabel, on: device)
            try await DiskMount.withMounted(iso) { root in
                try FileManager.default.copyItem(at: root.appending(path: "sources/install.wim"), to: volume.appending(path: "install.wim"))
            }
            try await DiskMount.withMounted(virtioWin) { root in
                for name in drivers {
                    let source = root.appending(path: "\(name)/w11/ARM64")
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let target = volume.appending(path: "drivers/\(name)")
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    // 调试符号占驱动目录的大头，部署用不到。
                    for file in try FileManager.default.contentsOfDirectory(atPath: source.path) where !file.hasSuffix(".pdb") {
                        try FileManager.default.copyItem(at: source.appending(path: file), to: target.appending(path: file))
                    }
                }
            }
        }
    }

    /// 读安装镜像 `sources/lang.ini` 里的界面语言；读不到时用 en-US。
    static func readLocale(iso: URL) async throws -> String {
        try await DiskMount.withMounted(iso) { root in
            let text = (try? String(contentsOf: root.appending(path: "sources/lang.ini"), encoding: .utf8))
                ?? (try? String(contentsOf: root.appending(path: "sources/lang.ini"), encoding: .utf16)) ?? ""
            var inSection = false
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inSection = line.lowercased() == "[available ui languages]"; continue }
                if inSection, let tag = line.split(separator: "=").first {
                    let parts = tag.trimmingCharacters(in: .whitespaces).split(separator: "-")
                    if parts.count == 2 { return "\(parts[0].lowercased())-\(parts[1].uppercased())" }
                }
            }
            return "en-US"
        }
    }

    static func cachedVirtioWin(showProgress: Bool) async throws -> URL {
        let cache = DownloadCache.root.appending(path: "virtio-win.iso")
        return try await Download.cached(cache, from: virtioWinURL, via: cache.appendingPathExtension("part"), showProgress: showProgress)
    }
}

/// 挂载磁盘镜像，用完卸载。
enum DiskMount {
    /// 以 raw 方式接上镜像但不挂载文件系统，交出 /dev/diskN，用完弹出。
    static func withAttachedRaw<T>(_ image: URL, _ body: (String) async throws -> T) async throws -> T {
        let output = try await Subprocess.run("/usr/bin/hdiutil", ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        guard let device = output.split(separator: "\n").first?.split(separator: " ").first.map(String.init), device.hasPrefix("/dev/disk") else {
            throw MacVMError.io("无法接上 \(image.lastPathComponent)：\(output)")
        }
        do {
            let result = try await body(device)
            _ = try? await Subprocess.run("/usr/sbin/diskutil", ["eject", device])
            return result
        } catch {
            _ = try? await Subprocess.run("/usr/sbin/diskutil", ["eject", device])
            throw error
        }
    }

    static func mountPoint(ofPartitionNamed name: String, on device: String) async throws -> URL {
        let list = try await Subprocess.run("/usr/sbin/diskutil", ["list", device])
        guard let line = list.split(separator: "\n").first(where: { $0.contains(name) }),
              let identifier = line.split(separator: " ").last else {
            throw MacVMError.io("找不到分区 \(name)")
        }
        let info = try await Subprocess.run("/usr/sbin/diskutil", ["info", String(identifier)])
        guard let mount = info.split(separator: "\n").first(where: { $0.contains("Mount Point:") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !mount.isEmpty else {
            throw MacVMError.io("分区 \(name) 未挂载")
        }
        return URL(filePath: mount, directoryHint: .isDirectory)
    }

    static func withMounted<T>(_ image: URL, _ body: (URL) async throws -> T) async throws -> T {
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "macvm-mnt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await Subprocess.run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        defer {
            _ = try? Process.run(URL(filePath: "/usr/bin/hdiutil"), arguments: ["detach", "-quiet", "-force", mountPoint.path]).waitUntilExit()
            try? FileManager.default.removeItem(at: mountPoint)
        }
        return try await body(mountPoint)
    }
}
