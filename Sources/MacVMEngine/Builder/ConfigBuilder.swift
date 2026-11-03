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

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // 显式的 XHCI 控制器只为运行时热插拔 U 盘，它会让通用平台虚拟机无法恢复，所以 headless 不挂。
        if #available(macOS 15, *), !config.headless {
            vz.usbControllers = [VZXHCIControllerConfiguration()]
        }

        if validate {
            do { try vz.validate() } catch {
                throw MacVMError.invalidConfig("配置无效：\(error.localizedDescription)")
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
                throw MacVMError.invalidConfig("缺少 Windows 启动盘 \(WindowsSupport.bootImageName)，启动前应先调用 RunnerFactory.prepare")
            }
            devices.append(VZVirtioBlockDeviceConfiguration(attachment: try diskAttachment(url: boot, readOnly: true, caching: .automatic, sync: .none)))
        }
        for disk in config.disks {
            devices.append(try storageDevice(for: disk))
        }
        for media in config.installMedia {
            let attachment = try diskAttachment(url: bundle.resolve(media), readOnly: true, caching: .automatic, sync: .none)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        vz.storageDevices = devices
    }

    private func storageDevice(for disk: DiskConfig) throws -> VZStorageDeviceConfiguration {
        let attachment = try diskAttachment(url: bundle.resolve(disk.path), readOnly: disk.readOnly, caching: disk.caching, sync: disk.sync)
        switch disk.bus {
        case .virtio: return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        case .nvme: return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
        case .usb: return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        }
    }

    private func diskAttachment(url: URL, readOnly: Bool, caching: DiskConfig.Caching, sync: DiskConfig.Sync) throws -> VZDiskImageStorageDeviceAttachment {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacVMError.invalidConfig("磁盘文件不存在：\(url.path)")
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
            throw MacVMError.engine("挂载磁盘 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 网络

    private func configureNetwork(_ vz: VZVirtualMachineConfiguration) throws {
        vz.networkDevices = try config.networks.map { net in
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = try NetworkAttachments.make(for: net)
            if let text = net.macAddress {
                guard let mac = VZMACAddress(string: text) else { throw MacVMError.invalidConfig("MAC 地址无效：\(text)") }
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
        case .linux, .windows:
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: d.width, heightInPixels: d.height)]
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

    /// Windows 没有 virtio-sound 驱动，挂上只会多一个无用设备。
    private func configureAudio(_ vz: VZVirtualMachineConfiguration) {
        guard config.audio, config.os != .windows else { return }
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        if config.microphone {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            sound.streams.append(input)
        }
        vz.audioDevices = [sound]
    }

    // MARK: - 共享目录

    private func configureDirectorySharing(_ vz: VZVirtualMachineConfiguration) throws {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        let shares = try config.shares.map { share -> (ShareConfig, VZSharedDirectory) in
            var isDir: ObjCBool = false
            let url = bundle.resolve(share.hostPath)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw MacVMError.invalidConfig("共享目录不存在：\(url.path)")
            }
            return (share, VZSharedDirectory(url: url, readOnly: share.readOnly))
        }

        if config.os == .macOS {
            // macOS 客户机只自动挂载这一个 tag，多个目录合并成它下面的子目录。
            if !shares.isEmpty {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
                device.share = VZMultipleDirectoryShare(directories: Dictionary(shares.map { ($0.0.tag, $0.1) }, uniquingKeysWith: { a, _ in a }))
                devices.append(device)
            }
        } else {
            for (share, directory) in shares {
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

    // MARK: - 控制台

    private func configureConsole(_ vz: VZVirtualMachineConfiguration) {
        guard case let .fileHandles(read, write) = console else { return }
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: read, fileHandleForWriting: write)
        vz.serialPorts = [port]
    }
}

enum RosettaShare {
    static let tag = "rosetta"

    static func make() throws -> VZVirtioFileSystemDeviceConfiguration {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: break
        case .notInstalled: throw MacVMError.unsupported("主机未安装 Rosetta，先运行 softwareupdate --install-rosetta")
        case .notSupported: throw MacVMError.unsupported("本机不支持 Linux Rosetta")
        @unknown default: throw MacVMError.unsupported("Rosetta 状态未知")
        }
        let share = try VZLinuxRosettaDirectoryShare()
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = share
        return device
    }
}
