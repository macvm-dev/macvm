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
    /// 后台运行（`macvm start`）时把客户机的 virtio 控制台输出写进 `VMBundle.logURL`。
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

    /// 能否把主机麦克风接给客户机：只有 VZ 的 virtio-sound 带输入流，与声音输出各自开关。
    public var supportsMicrophone: Bool { engine == .vz && supportsAudio }

    /// 声卡与麦克风只在开机时接上，运行中可改、下次开机生效。与开机时的 `booted` 不同时，
    /// 挂起保存的设备与恢复时按本配置组装的对不上，不能挂起。
    public func audioDiffers(from booted: VMConfig) -> Bool {
        audio != booted.audio || microphone != booted.microphone
    }

    public static let audioChangedSinceBootError = MacVMError.unsupported("开机后改过声音或麦克风设置，挂起后无法恢复，请关机：下次开机按新设置启动")

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
    /// 客户机分辨率跟随窗口时按屏幕像素而不是点数（QEMU 引擎与 VZ 下的 Linux）；Windows 同时把缩放比例调到屏幕倍数，界面大小不变而更清晰。
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

extension ShareConfig {
    /// virtio-fs tag 的最大字节数。
    public static let maxTagBytes = 36

    /// 由目录名生成 tag，与 `taken` 重复时加 `-2`、`-3`…，不超过 `maxTagBytes`。
    /// macOS 客户机里 tag 是 `My Shared Files` 下的目录名，保留原名；Linux 客户机要在 mount 命令里输入，
    /// 只留 ASCII 字母、数字与 `.`、`_`、`-`。
    public static func tag(for hostPath: String, os: GuestOS, taken: Set<String>) -> String {
        var base = URL(filePath: hostPath).lastPathComponent
        if os != .macOS {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            base = String(String.UnicodeScalarView(base.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        if base.isEmpty || base == "/" { base = "share" }
        var n = 1
        while true {
            let suffix = n == 1 ? "" : "-\(n)"
            let candidate = truncated(base, toBytes: maxTagBytes - suffix.utf8.count) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// 按字符截断，不切开多字节字符。
    private static func truncated(_ text: String, toBytes limit: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result
    }
}

extension VMConfig {
    /// 共享目录只能用 VZ 引擎挂载，Windows 客户机没有 virtio-fs 驱动。
    public var supportsShares: Bool { engine == .vz && os != .windows }

    /// 添加共享目录；`tag` 为 nil 时由目录名生成。目录不存在、已共享，或 `tag` 已被占用、超长时报错。
    public mutating func addShare(hostPath: String, tag: String? = nil, readOnly: Bool = false) throws {
        guard supportsShares else { throw MacVMError.unsupported("\(name) 不支持共享目录：只有 VZ 引擎的 macOS、Linux 客户机可以") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MacVMError.invalidConfig("共享目录不存在：\(hostPath)")
        }
        guard !shares.contains(where: { $0.hostPath == hostPath }) else { throw MacVMError.invalidConfig("已共享：\(hostPath)") }
        let taken = Set(shares.map(\.tag))
        if let tag {
            guard !tag.isEmpty, tag.utf8.count <= ShareConfig.maxTagBytes else {
                throw MacVMError.invalidConfig("共享名称应为 1 到 \(ShareConfig.maxTagBytes) 字节：\(tag)")
            }
            guard !taken.contains(tag) else { throw MacVMError.invalidConfig("共享名称已被占用：\(tag)") }
        }
        shares.append(ShareConfig(hostPath: hostPath, tag: tag ?? ShareConfig.tag(for: hostPath, os: os, taken: taken), readOnly: readOnly))
    }

    /// 按主机路径或 tag 移除共享目录，没有匹配的时报错。
    public mutating func removeShare(_ pathOrTag: String) throws {
        let before = shares.count
        shares.removeAll { $0.hostPath == pathOrTag || $0.tag == pathOrTag }
        guard shares.count < before else { throw MacVMError.invalidConfig("没有这个共享目录：\(pathOrTag)") }
    }
}

extension VMConfig {
    /// 改第一块网卡的网络模式，保留它的 MAC 地址：客户机按 MAC 认网卡，换了地址网络配置就对不上。
    /// `interface` 只用于 `bridged`，为 nil 时开机桥接到第一块可桥接的网卡。
    public mutating func setNetwork(_ mode: NetworkConfig.Mode, interface: String? = nil) {
        let mac = networks.first?.macAddress
        let net = NetworkConfig(mode: mode, interface: mode == .bridged ? interface : nil, macAddress: mac)
        if networks.isEmpty { networks = [net] } else { networks[0] = net }
    }
}
