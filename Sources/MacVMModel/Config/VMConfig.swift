public import Foundation

/// 一台虚拟机的持久化配置，存为包内的 `config.json`。
///
/// 新增字段必须给默认值并在 `init(from:)` 里用 `decodeIfPresent`，
/// 旧配置文件才能继续读取；不兼容的结构变化需提升 `currentVersion`。
public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var os: GuestOS
    public var engine: Engine
    public var cpuCount: Int
    /// 字节数。
    public var memorySize: UInt64
    public var disks: [DiskConfig]
    public var display: DisplayConfig
    public var networks: [NetworkConfig]
    public var shares: [ShareConfig]
    public var audio: Bool
    /// 把主机麦克风接给客户机；开启后主机会请求麦克风权限并亮起录音指示。
    public var microphone: Bool
    /// 仅 Linux 客户机有效。
    public var rosetta: Bool
    /// 以 USB 大容量存储只读挂载的安装介质，装完置空。
    public var installMedia: [String]
    /// 不挂键盘、指针与 USB 控制器，只用 SSH / 控制台访问。
    public var headless: Bool
    /// 客户机里可用 macvm 专用 SSH 密钥登录的用户；未知（如从安装介质手动安装）时为 nil。
    public var guestUser: String?
    /// 客户机里装有 macvm-agent，exec、端口转发、关机等走 vsock 而不依赖网络与 SSH。
    public var guestAgent: Bool
    /// 后台运行（`macvm start`）时把客户机的 virtio 控制台输出写进 `run.log`。
    public var serialConsole: Bool
    /// 客户机已拿到 3D 显卡驱动（Windows 的 viogpu3d），只能用带图形加速的 QEMU 运行：
    /// VZ 与不带 virglrenderer 的 QEMU 下它没有 3D 可用，Windows 开机即崩溃。
    public var graphicsAcceleration: Bool

    public init(
        name: String,
        os: GuestOS,
        engine: Engine = .vz,
        cpuCount: Int,
        memorySize: UInt64,
        disks: [DiskConfig],
        display: DisplayConfig = .init(),
        networks: [NetworkConfig] = [.init()],
        shares: [ShareConfig] = [],
        audio: Bool = true,
        microphone: Bool = false,
        rosetta: Bool = false,
        installMedia: [String] = [],
        headless: Bool = false,
        guestUser: String? = nil,
        guestAgent: Bool = false,
        serialConsole: Bool = false,
        graphicsAcceleration: Bool = false
    ) {
        self.version = Self.currentVersion
        self.name = name
        self.os = os
        self.engine = engine
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.disks = disks
        self.display = display
        self.networks = networks
        self.shares = shares
        self.audio = audio
        self.microphone = microphone
        self.rosetta = rosetta
        self.installMedia = installMedia
        self.headless = headless
        self.guestUser = guestUser
        self.guestAgent = guestAgent
        self.serialConsole = serialConsole
        self.graphicsAcceleration = graphicsAcceleration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .vz
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memorySize = try c.decode(UInt64.self, forKey: .memorySize)
        disks = try c.decode([DiskConfig].self, forKey: .disks)
        display = try c.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? .init()
        networks = try c.decodeIfPresent([NetworkConfig].self, forKey: .networks) ?? [.init()]
        shares = try c.decodeIfPresent([ShareConfig].self, forKey: .shares) ?? []
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        installMedia = try c.decodeIfPresent([String].self, forKey: .installMedia) ?? []
        headless = try c.decodeIfPresent(Bool.self, forKey: .headless) ?? false
        guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser)
        guestAgent = try c.decodeIfPresent(Bool.self, forKey: .guestAgent) ?? false
        serialConsole = try c.decodeIfPresent(Bool.self, forKey: .serialConsole) ?? false
        graphicsAcceleration = try c.decodeIfPresent(Bool.self, forKey: .graphicsAcceleration) ?? false
    }

    /// 能否挂声音设备。VZ 只有 virtio-sound，Windows 没有它的驱动。
    public var supportsAudio: Bool { engine == .qemu || os != .windows }

    /// 能否挂起。VZ 下通用平台（Linux、Windows）带 USB 控制器或 USB 设备时恢复会报 invalid argument，
    /// 而 `validateSaveRestoreSupport()` 并不拦截，因此在这里排除。
    public var supportsSuspend: Bool {
        guard installMedia.isEmpty else { return false }
        switch engine {
        case .qemu: return true
        case .vz:
            guard os.supportsSuspend else { return false }
            return os == .macOS || headless
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> VMConfig {
        let config = try JSONDecoder().decode(VMConfig.self, from: data)
        guard config.version <= currentVersion else {
            throw MacVMError.invalidConfig("config.json 版本 \(config.version) 高于本程序支持的 \(currentVersion)")
        }
        return config
    }
}

public struct DiskConfig: Codable, Sendable, Equatable {
    public enum Bus: String, Codable, Sendable { case virtio, nvme, usb }
    public enum Caching: String, Codable, Sendable { case automatic, cached, uncached }
    /// 对应 `VZDiskImageSynchronizationMode`。
    public enum Sync: String, Codable, Sendable { case full, fsync, none }

    /// 相对路径以包目录为基准。
    public var path: String
    public var readOnly: Bool
    public var bus: Bus
    public var caching: Caching
    public var sync: Sync

    public init(path: String, readOnly: Bool = false, bus: Bus = .virtio, caching: Caching = .automatic, sync: Sync = .fsync) {
        self.path = path
        self.readOnly = readOnly
        self.bus = bus
        self.caching = caching
        self.sync = sync
    }
}

public struct DisplayConfig: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixelsPerInch: Int
    /// 客户机分辨率跟随窗口时按屏幕像素而不是点数（QEMU 引擎）；Windows 同时把缩放比例调到屏幕倍数，界面大小不变而更清晰。
    public var retina: Bool

    public init(width: Int = 1920, height: Int = 1200, pixelsPerInch: Int = 144, retina: Bool = false) {
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
        self.retina = retina
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        pixelsPerInch = try c.decode(Int.self, forKey: .pixelsPerInch)
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? false
    }
}

public struct NetworkConfig: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case nat, bridged, vmnetShared, vmnetHost }

    public var mode: Mode
    /// `bridged` 时为主机网卡 BSD 名（如 en0）。
    public var interface: String?
    /// 形如 `xx:xx:xx:xx:xx:xx` 的本地管理地址；为空时由引擎生成并回写。
    public var macAddress: String?

    public init(mode: Mode = .nat, interface: String? = nil, macAddress: String? = nil) {
        self.mode = mode
        self.interface = interface
        self.macAddress = macAddress
    }
}

public struct ShareConfig: Codable, Sendable, Equatable {
    public var hostPath: String
    /// virtio-fs tag；macOS 客户机统一走自动挂载 tag，忽略此值。
    public var tag: String
    public var readOnly: Bool
    /// 要求客户机在与主机相同的绝对路径上暴露该目录。
    public var samePath: Bool

    public init(hostPath: String, tag: String, readOnly: Bool = false, samePath: Bool = false) {
        self.hostPath = hostPath
        self.tag = tag
        self.readOnly = readOnly
        self.samePath = samePath
    }
}
