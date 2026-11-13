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
    /// 在宿主与客户机之间同步文本剪贴板。macOS、Windows 客户机经代理同步，随时可改；
    /// Linux 客户机经开机时接上的 SPICE 通道同步，改了要下次开机生效（`clipboardChangeNeedsStop`）。
    public var clipboard: Bool
    /// 客户机空闲、显示器休眠后锁屏，回来要输密码。装了代理才生效：开机后代理上线时写进客户机，运行中改了立即生效；
    /// 关着时客户机不锁屏，开着时按客户机系统的默认。macOS 客户机要用包内保存的客户机密码。
    public var screenLock: Bool
    /// 客户机里已做到的 `GuestRevision`。新建的虚拟机由安装流程做到最新；没有这个字段的旧配置按 0。
    public var guestRevision: Int
    /// 客户机里可能留有的 MacVM 设的静态地址：开始往客户机里写之前记下，撤销成功后才清掉；为 nil 时客户机里没有 MacVM 设的静态地址。
    public var guestStaticIPv4: StaticIPv4?
    /// 运行期间由运行它的进程在宿主上监听；运行中改了经控制请求 `applyForwards` 立即生效。
    public var forwards: [PortForward]

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
        graphicsAcceleration: Bool = false,
        clipboard: Bool = true,
        screenLock: Bool = false,
        guestRevision: Int? = nil,
        forwards: [PortForward] = []
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
        self.clipboard = clipboard
        self.screenLock = screenLock
        self.guestRevision = guestRevision ?? GuestRevision.latest(for: os)
        self.guestStaticIPv4 = nil
        self.forwards = forwards
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
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
        screenLock = try c.decodeIfPresent(Bool.self, forKey: .screenLock) ?? false
        guestRevision = try c.decodeIfPresent(Int.self, forKey: .guestRevision) ?? 0
        guestStaticIPv4 = try c.decodeIfPresent(StaticIPv4.self, forKey: .guestStaticIPv4)
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
    }

    /// 改剪贴板同步是否要先关机：Linux 客户机的 SPICE 通道是开机时接上的设备，挂起的存档也认这套设备。
    public var clipboardChangeNeedsStop: Bool { os == .linux }

    /// 能否挂声音设备。VZ 只有 virtio-sound，Windows 没有它的驱动。
    public var supportsAudio: Bool { engine == .qemu || os != .windows }

    /// 能否把主机麦克风接给客户机：只有 VZ 的 virtio-sound 带输入流，与声音输出各自开关。
    public var supportsMicrophone: Bool { engine == .vz && supportsAudio }

    /// 声卡与麦克风只在开机时接上，运行中可改、下次开机生效。与开机时的 `booted` 不同时，
    /// 挂起保存的设备与恢复时按本配置组装的对不上，不能挂起。
    public func audioDiffers(from booted: VMConfig) -> Bool {
        audio != booted.audio || microphone != booted.microphone
    }

    public static let audioChangedSinceBootError = MacVMError.unsupported(String(l10n: "Sound or microphone settings changed after startup, so the suspended virtual machine can't resume. Shut it down; it'll use the new settings the next time it starts."))

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
            throw MacVMError.invalidConfig(String(l10n: "config.json version \(config.version) is newer than this version of MacVM supports (\(currentVersion))"))
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
    public enum Mode: String, Codable, Sendable {
        case nat, vmnetShared, vmnetHost
        /// 经 `VZBridgedNetworkDeviceAttachment` 桥接到宿主网卡。
        case bridged = "vzBridged"
    }

    public var mode: Mode
    /// `bridged` 时是宿主网卡的 BSD 名（如 `en0`），此时必须有值；其他模式为 nil。
    public var interface: String?
    /// 形如 `xx:xx:xx:xx:xx:xx` 的本地管理地址；为空时由引擎生成并回写。
    public var macAddress: String?
    /// 只在 `bridged` 时有值，为 nil 时客户机用 DHCP。
    public var staticIPv4: StaticIPv4?

    public init(mode: Mode = .nat, interface: String? = nil, macAddress: String? = nil, staticIPv4: StaticIPv4? = nil) {
        self.mode = mode
        self.interface = interface
        self.macAddress = macAddress
        self.staticIPv4 = staticIPv4
    }

    /// 原始值 `bridged` 按 `nat` 读并丢掉它的 `interface`，MAC 地址照旧，客户机里的网卡配置仍对得上；
    /// `interface` 与 `staticIPv4` 只在 `vzBridged` 时读取，`vzBridged` 必须带上 `interface`。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .mode)
        if raw == "bridged" {
            mode = .nat
        } else if let mode = Mode(rawValue: raw) {
            self.mode = mode
        } else {
            throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "Unknown network mode \(raw)")
        }
        interface = mode == .bridged ? try c.decodeIfPresent(String.self, forKey: .interface) : nil
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        staticIPv4 = mode == .bridged ? try c.decodeIfPresent(StaticIPv4.self, forKey: .staticIPv4) : nil
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
        guard supportsShares else { throw MacVMError.unsupported(String(l10n: "\(name) doesn't support shared folders; only macOS and Linux guests using the vz engine do")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MacVMError.invalidConfig(String(l10n: "Shared folder doesn't exist: \(hostPath)"))
        }
        guard !shares.contains(where: { $0.hostPath == hostPath }) else { throw MacVMError.invalidConfig(String(l10n: "This folder is already shared: \(hostPath)")) }
        let taken = Set(shares.map(\.tag))
        if let tag {
            guard !tag.isEmpty, tag.utf8.count <= ShareConfig.maxTagBytes else {
                throw MacVMError.invalidConfig(String(l10n: "Share name must be 1 to \(ShareConfig.maxTagBytes) bytes: \(tag)"))
            }
            guard !taken.contains(tag) else { throw MacVMError.invalidConfig(String(l10n: "Share name already in use: \(tag)")) }
        }
        shares.append(ShareConfig(hostPath: hostPath, tag: tag ?? ShareConfig.tag(for: hostPath, os: os, taken: taken), readOnly: readOnly))
    }

    /// 按主机路径或 tag 移除共享目录，没有匹配的时报错。
    public mutating func removeShare(_ pathOrTag: String) throws {
        let before = shares.count
        shares.removeAll { $0.hostPath == pathOrTag || $0.tag == pathOrTag }
        guard shares.count < before else { throw MacVMError.invalidConfig(String(l10n: "No shared folder matches \(pathOrTag)")) }
    }
}

extension VMConfig {
    /// 改第一块网卡的网络模式，保留它的 MAC 地址：客户机按 MAC 认网卡，换了地址网络配置就对不上。
    /// `interface` 只用于 `bridged`，是宿主网卡的 BSD 名，桥接时必填。QEMU 引擎不能桥接；Windows 客户机也不能，
    /// 它在 VZ 上的代理只走 TCP，宿主要先知道客户机 IP。切回 NAT 不受引擎和系统限制。
    /// 桥接时保留原有的 `NetworkConfig.staticIPv4`，切回 NAT 时丢掉。
    public mutating func setNetwork(_ mode: NetworkConfig.Mode, interface: String? = nil) throws {
        if mode == .bridged {
            if engine == .qemu { throw MacVMError.unsupported(String(l10n: "\(name) uses the qemu engine, which doesn't support bridged networking")) }
            if os == .windows { throw MacVMError.unsupported(String(l10n: "Windows guests don't support bridged networking")) }
            guard let interface, !interface.isEmpty else { throw MacVMError.invalidConfig(String(l10n: "Bridged networking needs a host network interface")) }
        }
        let bridged = mode == .bridged
        let net = NetworkConfig(mode: mode, interface: bridged ? interface : nil, macAddress: networks.first?.macAddress,
                                staticIPv4: bridged ? networks.first?.staticIPv4 : nil)
        if networks.isEmpty { networks = [net] } else { networks[0] = net }
    }

    /// 设第一块网卡的静态 IPv4，nil 改回 DHCP、任何时候都允许。设地址要求第一块网卡是 `bridged` 且装有客户机代理。
    public mutating func setStaticIPv4(_ value: StaticIPv4?) throws {
        if let value {
            guard networks.first?.mode == .bridged else {
                throw MacVMError.invalidConfig(String(l10n: "Static IP addresses need bridged networking"))
            }
            guard guestAgent else { throw MacVMError.unsupported(String(l10n: "Static IP addresses need the guest agent")) }
            try value.validate()
        }
        guard !networks.isEmpty else { return }
        networks[0].staticIPv4 = value
    }
}
