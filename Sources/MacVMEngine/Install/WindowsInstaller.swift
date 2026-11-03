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
    public static var doneMarker: String { WindowsUnattend.doneMarker }
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
        public var showProgress: Bool

        public init(name: String, iso: URL, virtioWin: URL? = nil, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                    user: String = NSUserName(), password: String? = nil, showProgress: Bool = false) {
            self.name = name
            self.iso = iso
            self.virtioWin = virtioWin
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
            self.user = user
            self.password = password
            self.showProgress = showProgress
        }
    }

    /// 建好包与安装盘；之后 `start` 即开始安装，完成与否看 `isSetupComplete`。
    public static func create(_ options: Options, in library: VMLibrary = .default) async throws -> VMBundle {
        let qemu = try QEMUInstallation.require()
        try VMLibrary.validate(name: options.name)
        guard FileManager.default.fileExists(atPath: options.iso.path) else { throw MacVMError.invalidConfig("ISO 不存在：\(options.iso.path)") }
        if FileManager.default.fileExists(atPath: library.bundleURL(named: options.name).path) { throw MacVMError.alreadyExists(options.name) }

        let locale = try await readLocale(iso: options.iso)
        var virtioWin = options.virtioWin
        if virtioWin == nil { virtioWin = try await cachedVirtioWin(showProgress: options.showProgress) }
        let password = options.password ?? GuestCredentials.randomPassword()
        let unattend = WindowsUnattend.Options(
            computerName: String(options.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(15)),
            user: options.user, password: password, locale: locale,
            sshPublicKey: try await SSHKeys.ensurePublicKey()
        )

        let bundle = try VMFactory.prepareEmptyBundle(named: options.name, in: library)
        do {
            try await buildSetupImage(unattend, to: bundle.url.appending(path: setupImageName))
            try await buildDataImage(iso: options.iso, virtioWin: virtioWin!, to: bundle.url.appending(path: dataImageName))
            try DiskImage.createSparse(at: bundle.diskURL, size: options.diskSize ?? HostInfo.defaultDiskSize(for: .windows))
            try MachineIdentity.createGeneric(in: bundle)
            try qemu.ensureVars(for: bundle)
            try GuestCredentials.storePassword(password, in: bundle)
            let config = VMConfig(
                name: options.name, os: .windows, engine: .qemu,
                cpuCount: options.cpuCount ?? HostInfo.defaultCPUCount(),
                memorySize: options.memorySize ?? HostInfo.defaultMemorySize(for: .windows),
                disks: [DiskConfig(path: bundle.diskURL.lastPathComponent, bus: .nvme), DiskConfig(path: dataImageName, bus: .nvme)],
                networks: [NetworkConfig(macAddress: NetworkAttachments.randomMACAddress())],
                installMedia: [options.iso.path, setupImageName],
                guestUser: options.user
            )
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    /// 轮询直到首次登录脚本写下完成标记。`proxyCommand` 是 ssh 的 ProxyCommand（`macvm proxy <名>`）。
    public static func waitUntilSetupComplete(_ bundle: VMBundle, proxyCommand: String, timeout: TimeInterval = 3 * 3600) async throws {
        let config = try bundle.loadConfig()
        guard let user = config.guestUser else { throw MacVMError.invalidConfig("缺少客户机用户") }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if BundleLock.holder(of: bundle) == nil { throw MacVMError.engine("安装过程中虚拟机意外停止，日志：\(bundle.logURL.path)") }
            let output = try? await Subprocess.run("/usr/bin/ssh", [
                "-q", "-T", "-i", SSHKeys.privateKeyURL.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "ProxyCommand=\(proxyCommand)", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=20", "\(user)@\(SSHConfig.hostAlias(for: bundle.name))", "Test-Path \(doneMarker)",
            ])
            if output?.contains("True") == true { return }
            guard Date() < deadline else { throw MacVMError.timeout("Windows 安装超时") }
            try await Task.sleep(for: .seconds(15))
        }
    }

    /// 安装完成后卸下安装介质与数据盘并删除它们（安装盘含明文密码）。
    public static func finishSetup(_ bundle: VMBundle) throws {
        var config = try bundle.loadConfig()
        config.installMedia = []
        config.disks.removeAll { $0.path == dataImageName }
        try bundle.saveConfig(config)
        for name in [setupImageName, dataImageName] {
            try? FileManager.default.removeItem(at: bundle.url.appending(path: name))
        }
    }

    // MARK: - 安装盘

    static func buildSetupImage(_ o: WindowsUnattend.Options, to output: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "macvm-winsetup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try WindowsUnattend.autounattend().write(to: staging.appending(path: "autounattend.xml"), atomically: true, encoding: .utf8)
        try WindowsUnattend.unattend(o).write(to: staging.appending(path: "unattend.xml"), atomically: true, encoding: .utf8)
        try WindowsUnattend.installScript().write(to: staging.appending(path: WindowsUnattend.installScriptName), atomically: true, encoding: .ascii)
        try WindowsUnattend.setupScript(o).write(to: staging.appending(path: "setup.ps1"), atomically: true, encoding: .utf8)

        let dmg = output.deletingPathExtension().appendingPathExtension("dmg")
        try await Subprocess.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", "MS-DOS", "-fsargs", "-F 32",
                                                      "-volname", WindowsUnattend.volumeLabel, "-layout", "NONE", "-format", "UDRW",
                                                      "-srcfolder", staging.path, "-ov", dmg.path])
        try FileManager.default.moveItem(at: dmg, to: output)
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
        let cache = ImageCache.root.deletingLastPathComponent().appending(path: "virtio-win.iso")
        if FileManager.default.fileExists(atPath: cache.path) { return cache }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = cache.appendingPathExtension("part")
        try await Subprocess.run("/usr/bin/curl", ["-fL", "--retry", "3", "-C", "-", showProgress ? "--progress-bar" : "-sS", "-o", partial.path, virtioWinURL.absoluteString],
                                 passthroughStderr: showProgress)
        try FileManager.default.moveItem(at: partial, to: cache)
        return cache
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
