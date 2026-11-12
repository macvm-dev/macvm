public import Foundation
public import MacVMModel
@preconcurrency public import Virtualization

/// 把 `VMConfig` 翻译成 `VZVirtualMachineConfiguration`。
///
/// 平台与引导部分按客户机系统分在各自的扩展里，其余设备在这里统一组装。
public struct ConfigBuilder {
    public enum Console {
        case none
        /// 接到给定的读写句柄（stdio 或日志文件）。
        case fileHandles(read: FileHandle?, write: FileHandle)
    }

    public let bundle: VMBundle
    public let config: VMConfig
    public var console: Console = .none

    public init(bundle: VMBundle, config: VMConfig) {
        self.bundle = bundle
        self.config = config
    }

    /// `validate` 为 false 时跳过 `VZVirtualMachineConfiguration.validate()`：
    /// 它要求调用进程带 virtualization entitlement，而组装阶段的错误不依赖它。
    public func build(validate: Bool = true) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = clampedCPUCount
        vz.memorySize = clampedMemorySize

        switch config.os {
        case .macOS: try configureMacOSPlatform(vz)
        case .linux: try configureLinuxPlatform(vz)
        case .windows: try configureWindowsPlatform(vz)
        }

        try configureStorage(vz)
        try configureNetwork(vz)
        configureGraphics(vz)
        configureInput(vz)
        configureAudio(vz)
        try configureDirectorySharing(vz)
        configureConsole(vz)
        configureClipboard(vz)

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // 显式的 XHCI 控制器只为运行时热插拔 U 盘，它会让通用平台虚拟机无法恢复，所以 headless 不挂。
        if !config.headless {
            vz.usbControllers = [VZXHCIControllerConfiguration()]
        }

        if validate {
            do { try vz.validate() } catch {
                throw MacVMError.invalidConfig(String(l10n: "Invalid configuration: \(error.localizedDescription)"))
            }
        }
        return vz
    }

    // MARK: - 资源

    var clampedCPUCount: Int {
        let lower = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let upper = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.activeProcessorCount)
        return min(max(config.cpuCount, lower), upper)
    }

    /// VZ 要求内存是 1 MiB 的整数倍。
    var clampedMemorySize: UInt64 {
        let mib: UInt64 = 1 << 20
        let lower = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let upper = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(config.memorySize, lower), upper) / mib * mib
    }

    // MARK: - 存储

    private func configureStorage(_ vz: VZVirtualMachineConfiguration) throws {
        var devices: [VZStorageDeviceConfiguration] = []
        if config.os == .windows {
            let boot = WindowsSupport.bootImageURL(bundle)
            guard FileManager.default.fileExists(atPath: boot.path) else {
                throw MacVMError.invalidConfig(String(l10n: "Missing Windows boot disk \(WindowsSupport.bootImageName); the runner should be created through RunnerFactory.make"))
            }
            devices.append(VZVirtioBlockDeviceConfiguration(attachment: try Self.diskAttachment(url: boot, readOnly: true, caching: .automatic, sync: .none)))
        }
        for disk in config.disks {
            devices.append(try storageDevice(for: disk))
        }
        for media in config.installMedia {
            let attachment = try Self.diskAttachment(url: bundle.resolve(media), readOnly: true, caching: .automatic, sync: .none)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        vz.storageDevices = devices
    }

    private func storageDevice(for disk: DiskConfig) throws -> VZStorageDeviceConfiguration {
        let attachment = try Self.diskAttachment(url: bundle.resolve(disk.path), readOnly: disk.readOnly, caching: disk.caching, sync: disk.sync)
        switch disk.bus {
        case .virtio: return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        case .nvme: return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
        case .usb: return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        }
    }

    static func diskAttachment(url: URL, readOnly: Bool, caching: DiskConfig.Caching, sync: DiskConfig.Sync) throws -> VZDiskImageStorageDeviceAttachment {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacVMError.invalidConfig(String(l10n: "Disk file not found: \(url.path)"))
        }
        let cachingMode: VZDiskImageCachingMode = switch caching {
        case .automatic: .automatic
        case .cached: .cached
        case .uncached: .uncached
        }
        let syncMode: VZDiskImageSynchronizationMode = switch sync {
        case .full: .full
        case .fsync: .fsync
        case .none: .none
        }
        do {
            return try VZDiskImageStorageDeviceAttachment(url: url, readOnly: readOnly, cachingMode: cachingMode, synchronizationMode: syncMode)
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't attach disk \(url.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    // MARK: - 网络

    private func configureNetwork(_ vz: VZVirtualMachineConfiguration) throws {
        vz.networkDevices = try config.networks.map { net in
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = try NetworkAttachments.make(for: net)
            if let text = net.macAddress {
                guard let mac = VZMACAddress(string: text) else { throw MacVMError.invalidConfig(String(l10n: "Invalid MAC address: \(text)")) }
                device.macAddress = mac
            }
            return device
        }
    }

    // MARK: - 显示与输入

    private func configureGraphics(_ vz: VZVirtualMachineConfiguration) {
        let d = config.display
        switch config.os {
        case .macOS:
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: d.width, heightInPixels: d.height, pixelsPerInch: d.pixelsPerInch)]
            vz.graphicsDevices = [graphics]
        case .linux:
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: d.width, heightInPixels: d.height)]
            vz.graphicsDevices = [graphics]
        case .windows:
            let size = WindowsSupport.displaySize
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: size.width, heightInPixels: size.height)]
            vz.graphicsDevices = [graphics]
        }
    }

    private func configureInput(_ vz: VZVirtualMachineConfiguration) {
        guard !config.headless else { return }
        switch config.os {
        case .macOS:
            vz.keyboards = [VZMacKeyboardConfiguration()]
            // 触控板给支持它的 macOS 13+ 客户机，USB 绝对定位兜底更老的系统与恢复模式。
            vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        case .linux, .windows:
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }

    // MARK: - 音频

    /// 声音输出与麦克风输入是同一块 virtio-sound 上的两路流，各自开关；两路都关时不挂声卡。
    private func configureAudio(_ vz: VZVirtualMachineConfiguration) {
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if config.audio, config.supportsAudio {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            streams.append(output)
        }
        if config.microphone, config.supportsMicrophone {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        guard !streams.isEmpty else { return }
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = streams
        vz.audioDevices = [sound]
    }

    // MARK: - 共享目录

    private func configureDirectorySharing(_ vz: VZVirtualMachineConfiguration) throws {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        if config.os == .macOS {
            // 没有共享目录也挂上：运行中改共享目录只能换已有设备的 share，不能加设备。
            // 恢复挂起状态时设备要与挂起时一致，状态里没有它就不挂。
            let restoringWithoutDevice = bundle.hasSavedState && !bundle.savedStateHasShareDevice
            if !config.shares.isEmpty || !restoringWithoutDevice {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
                device.share = try Self.macOSShare(config.shares, in: bundle)
                devices.append(device)
            }
        } else {
            for (share, directory) in try Self.sharedDirectories(config.shares, in: bundle) {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(share.tag)
                let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
                device.share = VZSingleDirectoryShare(directory: directory)
                devices.append(device)
            }
        }

        if config.rosetta, config.os == .linux {
            devices.append(try RosettaShare.make())
        }
        vz.directorySharingDevices = devices
    }

    /// macOS 客户机只自动挂载 `macOSGuestAutomountTag` 这一个 tag，各共享目录以 tag 为名合并成它下面的子目录。
    static func macOSShare(_ shares: [ShareConfig], in bundle: VMBundle) throws -> VZMultipleDirectoryShare {
        let directories = try sharedDirectories(shares, in: bundle)
        return VZMultipleDirectoryShare(directories: Dictionary(directories.map { ($0.0.tag, $0.1) }, uniquingKeysWith: { a, _ in a }))
    }

    private static func sharedDirectories(_ shares: [ShareConfig], in bundle: VMBundle) throws -> [(ShareConfig, VZSharedDirectory)] {
        try shares.map { share in
            var isDir: ObjCBool = false
            let url = bundle.resolve(share.hostPath)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw MacVMError.invalidConfig(String(l10n: "Shared folder not found: \(url.path)"))
            }
            return (share, VZSharedDirectory(url: url, readOnly: share.readOnly))
        }
    }

    // MARK: - 控制台

    private func configureConsole(_ vz: VZVirtualMachineConfiguration) {
        guard case let .fileHandles(read, write) = console else { return }
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: read, fileHandleForWriting: write)
        vz.serialPorts = [port]
    }

    // MARK: - 剪贴板

    /// Linux 客户机里的 spice-vdagent 经这个端口与宿主共享文本剪贴板。headless 时不挂：没有画面就用不上剪贴板，
    /// 而 headless 的 Linux 虚拟机要能挂起，多一个设备的配置恢复不了已有的存档。
    private func configureClipboard(_ vz: VZVirtualMachineConfiguration) {
        guard config.os == .linux, config.clipboard, !config.headless else { return }
        let attachment = VZSpiceAgentPortAttachment()
        attachment.sharesClipboard = true
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = attachment
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = port
        vz.consoleDevices = [console]
    }
}

enum RosettaShare {
    static let tag = "rosetta"

    static func make() throws -> VZVirtioFileSystemDeviceConfiguration {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: break
        case .notInstalled: throw MacVMError.unsupported(String(l10n: "Rosetta isn't installed on this Mac; run softwareupdate --install-rosetta first"))
        case .notSupported: throw MacVMError.unsupported(String(l10n: "This Mac doesn't support Rosetta for Linux"))
        @unknown default: throw MacVMError.unsupported(String(l10n: "Couldn't tell whether Rosetta is available"))
        }
        let share = try VZLinuxRosettaDirectoryShare()
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = share
        return device
    }
}
