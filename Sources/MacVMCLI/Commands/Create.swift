public import ArgumentParser
import Foundation
import MacVMEngine
public import MacVMModel

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "创建虚拟机。",
        discussion: """
        macOS：从 IPSW 安装，不给 --ipsw 时下载本机支持的最新版本（约 15–20 GB，缓存在下载目录的 ipsw 下）。装好后首次开机自动创建用户、
        自动登录并开启 SSH，装入 macvm 专用密钥与客户机代理、把主机名设为虚拟机名，再执行 macvm tune 的全部项（--no-tune 跳过）。
          macvm create mac --os macos
        Windows 11 ARM64：用 QEMU 引擎（需 brew install qemu）从原版 ISO 无人值守安装，装好即带用户与 OpenSSH。
          macvm create win --os windows --iso ~/Downloads/Win11_arm64.iso
        Linux 云镜像（推荐）：--image 指定镜像，首次使用时下载并缓存；开机即带用户与 macvm 专用 SSH 密钥。
          macvm create dev --image debian-13 --memory 8G
        Linux 桌面版：--desktop 下载发行方的桌面版安装 ISO（校验 SHA-256 并缓存）。Ubuntu 默认离线无人值守安装，装好即带用户与 SSH 公钥，
        加 --manual-install 改为图形安装；Fedora 开机后在窗口里完成图形安装。
          macvm create desk --desktop ubuntu-desktop
        安装介质：创建空磁盘，从 --iso 指定的介质启动安装（Linux、Windows）。
          macvm create box --os linux --iso ~/Downloads/fedora-aarch64.iso
        模板：复制 macvm template save 存下的模板（任何系统，含 macOS），可另指定 --cpus、--memory、--disk（只能扩大）、--network、--engine。
          macvm create dev2 --template dev-base
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "虚拟机名称（字母、数字、. _ -，最长 40）。")
    var name: String

    @Option(name: .customLong("os"), help: "客户机系统：linux（默认）、windows、macos。")
    var osOption: GuestOS?

    var os: GuestOS { osOption ?? .linux }

    @Option(help: "从模板新建（见 macvm template）。")
    var template: String?

    @Option(name: .customLong("cpus"), help: "vCPU 数，默认 4，且不超过主机核数。")
    var cpuCount: Int?

    @Option(help: "内存，如 4G。默认 8G，且不超过主机内存一半。")
    var memory: String?

    @Option(help: "磁盘容量（稀疏，按实际写入占用），如 64G。")
    var disk: String?

    @Option(help: ArgumentHelp("Linux 云镜像。", valueName: LinuxImage.catalog.map(\.id).joined(separator: "|")))
    var image: String?

    @Option(help: ArgumentHelp("Linux 桌面版：下载官方安装 ISO 并以它启动。Ubuntu 自动安装，Fedora 在窗口里图形安装。", valueName: LinuxDesktop.allCases.map(\.rawValue).joined(separator: "|")))
    var desktop: String?

    @Flag(help: "Ubuntu 桌面版：不自动安装，开机后在窗口里图形安装。")
    var manualInstall = false

    @Option(help: "云镜像、自动安装的 Ubuntu 桌面版与 Windows 里创建的登录用户，默认与主机用户同名。")
    var user: String?

    @Option(help: "Linux 云镜像、自动安装的 Ubuntu 桌面版与 Windows：登录密码，保存在虚拟机包内的 guest-password。省略时云镜像只能用 SSH 密钥登录，Ubuntu 桌面版与 Windows 随机生成。")
    var password: String?

    @Option(name: .customLong("iso"), help: "以只读 U 盘挂载的安装介质，可重复。Windows 只取一张，省略时从微软下载。")
    var installMedia: [String] = []

    @Option(help: "共享目录：主机路径[:tag][:ro]，可重复。")
    var share: [String] = []

    @Option(help: "网络：nat（默认）或 bridged[:网卡名]。")
    var network: String?

    @Flag(help: "Linux：挂载 Rosetta，运行 x86_64 程序。")
    var rosetta = false

    @Flag(inversion: .prefixedNo, help: "不挂键盘鼠标，只用 SSH 访问；可挂起。云镜像默认开启，安装介质默认关闭。")
    var headless: Bool?

    @Option(help: "Windows：virtio-win 驱动 ISO，省略时下载并缓存。")
    var virtioWin: String?

    @Option(help: "虚拟化引擎：vz（默认，资源占用最低）或 qemu（功能更全）。Windows 安装总是用 qemu。")
    var engine: Engine?

    @Option(name: .customLong("product-key"), help: "Windows：产品密钥，装好后联网激活；不写进虚拟机配置。省略时不激活。")
    var productKey: String?

    @Flag(help: "Windows：只建好虚拟机，不立即开始安装。")
    var noInstall = false

    @Flag(help: "后台运行时把客户机控制台输出写进 run.log。")
    var console = false

    @Option(help: "macOS：本地 IPSW 文件，省略时下载本机支持的最新版本。")
    var ipsw: String?

    @Option(help: "macOS：显示分辨率，默认 1920x1200。")
    var resolution: String?

    @Flag(help: "macOS：装完不开机配置 SSH、代理与调优。")
    var noProvision = false

    @Flag(help: "macOS：开通后不执行 macvm tune。")
    var noTune = false

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已创建 \(s.name)：\(s.path)" }) {
            if let template { return try await createFromTemplate(template) }
            if let user { try GuestAccount.validate(user: user) }
            if let password { try GuestAccount.validate(password: password) }
            if os == .macOS { return try await createMacOS() }
            let macOnly: [(String, Bool)] = [
                ("--ipsw", ipsw != nil), ("--resolution", resolution != nil), ("--no-provision", noProvision), ("--no-tune", noTune),
            ]
            if let option = macOnly.first(where: \.1)?.0 { throw MacVMError.invalidConfig("\(option) 只用于 macOS 客户机") }
            if os == .windows {
                if image != nil || desktop != nil { throw MacVMError.invalidConfig("--image 与 --desktop 只用于 Linux 客户机") }
                if let network, network != "nat" { throw MacVMError.invalidConfig("Windows 用 NAT 网络安装，装好后再用 macvm set --network 改") }
                let ignored: [(String, Bool)] = [
                    ("--share", !share.isEmpty), ("--rosetta", rosetta), ("--headless", headless != nil),
                    ("--console", console), ("--manual-install", manualInstall),
                ]
                if let option = ignored.first(where: \.1)?.0 { throw MacVMError.invalidConfig("\(option) 不用于 Windows 客户机") }
                try Self.validateDefaultUser(user)
                return try await createWindows()
            }
            if productKey != nil { throw MacVMError.invalidConfig("--product-key 只用于 Windows") }
            let desktop = try desktop.map(LinuxDesktop.named)
            if manualInstall, desktop?.supportsUnattended != true {
                throw MacVMError.invalidConfig("--manual-install 只用于能自动安装的桌面版（--desktop ubuntu-desktop）")
            }
            if engine == .qemu { _ = try QEMUInstallation.require() }
            let options = VMFactory.Options(
                name: name, os: os, cpuCount: cpuCount,
                memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
                installMedia: installMedia, network: try Self.parseNetwork(network ?? "nat"),
                shares: try Self.shareConfigs(share, name: name, os: os, engine: engine ?? .vz), rosetta: rosetta, serialConsole: console,
                image: try image.map(LinuxImage.named), desktop: desktop, unattended: !manualInstall, user: user ?? NSUserName(), password: password,
                showProgress: interactive, headless: headless
            )
            if password != nil, image == nil, !options.autoinstalls {
                throw MacVMError.invalidConfig("--password 只用于 Linux 云镜像（--image）、自动安装的 Ubuntu 桌面版与 Windows")
            }
            if image != nil || options.autoinstalls { try Self.validateDefaultUser(user) }
            let bundle = try await VMFactory.createEFIGuest(options)
            if let engine, engine != .vz {
                var config = try bundle.loadConfig()
                config.engine = engine
                try bundle.saveConfig(config)
            }
            SSHConfigCommand.refresh()
            if options.autoinstalls { try await installUbuntu(bundle) }
            return try VMStatus.summary(of: bundle)
        }
    }

    private func createFromTemplate(_ name: String) async throws -> VMSummary {
        let conflicting: [(String, Bool)] = [
            ("--image", image != nil), ("--desktop", desktop != nil), ("--manual-install", manualInstall), ("--user", user != nil),
            ("--password", password != nil), ("--iso", !installMedia.isEmpty), ("--share", !share.isEmpty), ("--rosetta", rosetta),
            ("--headless", headless != nil), ("--virtio-win", virtioWin != nil), ("--product-key", productKey != nil),
            ("--no-install", noInstall), ("--console", console), ("--ipsw", ipsw != nil), ("--resolution", resolution != nil),
            ("--no-provision", noProvision), ("--no-tune", noTune),
        ]
        if let option = conflicting.first(where: \.1)?.0 {
            throw MacVMError.invalidConfig("\(option) 不能与 --template 同用：系统、账户与设备都沿用模板")
        }
        let template = try TemplateLibrary.default.template(named: name)
        if let osOption, osOption != (try template.loadConfig()).os {
            throw MacVMError.invalidConfig("模板 \(name) 不是 \(osOption.rawValue) 客户机")
        }
        let network = try network.map(Self.parseNetwork)
        let bundle = try await VMTemplate.instantiate(
            template, as: self.name, cpuCount: cpuCount, memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse)
        ) { config in
            if let network { config.setNetwork(network.mode, interface: network.interface) }
            if let engine { try config.switchEngine(to: engine) }
        }
        SSHConfigCommand.refresh()
        return try VMStatus.summary(of: bundle)
    }

    /// 进度只在人看的终端上写到标准错误。
    private var interactive: Bool { !global.json && isatty(STDERR_FILENO) == 1 }

    private func say(_ text: String) {
        if interactive { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }

    private func installUbuntu(_ bundle: VMBundle) async throws {
        say("开始离线自动安装 Ubuntu…")
        _ = try await Start.launch(bundle, timeout: 120)
        try await UbuntuAutoinstall.completeSetup(bundle) {
            _ = try await Start.launch(bundle, timeout: 120)
        }
        say("Ubuntu 已就绪：macvm exec \(name) -- whoami；密码见 \(GuestCredentials.passwordURL(bundle).path)")
    }

    /// 网络与共享目录不在安装时设置：首次开机经 NAT 下的客户机 IP 开通 SSH，装好后用 `macvm set` 改。
    @MainActor
    private func createMacOS() async throws -> VMSummary {
        let unsupported: [(String, Bool)] = [
            ("--image", image != nil), ("--desktop", desktop != nil), ("--manual-install", manualInstall), ("--iso", !installMedia.isEmpty),
            ("--rosetta", rosetta), ("--headless", headless != nil), ("--virtio-win", virtioWin != nil),
            ("--product-key", productKey != nil), ("--no-install", noInstall), ("--console", console), ("--engine qemu", engine == .qemu),
        ]
        if let option = unsupported.first(where: \.1)?.0 { throw MacVMError.invalidConfig("\(option) 不用于 macOS 客户机") }
        if let network, network != "nat" { throw MacVMError.invalidConfig("macOS 用 NAT 网络安装，装好后再用 macvm set --network 改") }
        if !share.isEmpty { throw MacVMError.invalidConfig("macOS 安装时不挂共享目录，装好后再用 macvm set --add-share 加") }
        try Self.validateDefaultUser(user)
        let user = user ?? NSUserName()
        let resolution = resolution ?? "1920x1200"
        guard let (width, height) = Display.parse(resolution) else {
            throw MacVMError.invalidConfig("分辨率格式应为 宽x高：\(resolution)")
        }
        let interactive = interactive
        let options = MacOSInstaller.Options(
            name: name,
            source: ipsw.map { .file(URL(filePath: ($0 as NSString).expandingTildeInPath)) } ?? .latest,
            cpuCount: cpuCount, memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
            user: user, password: password,
            display: DisplayConfig(width: width, height: height, pixelsPerInch: 144),
            showProgress: interactive
        )
        var lastPercent = -1
        let bundle = try await MacOSInstaller.install(options) { phase in
            guard interactive else { return }
            switch phase {
            case .downloading: FileHandle.standardError.write(Data("下载 IPSW…\n".utf8))
            case .installing(let f):
                let percent = Int(f * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    FileHandle.standardError.write(Data("\r安装 macOS：\(percent)%".utf8))
                }
            }
        }
        if interactive { FileHandle.standardError.write(Data("\n".utf8)) }
        SSHConfigCommand.refresh()
        guard !noProvision, let pw = GuestCredentials.password(for: bundle) else { return try VMStatus.summary(of: bundle) }

        say("首次开机并配置 SSH（可能需要几分钟）…")
        try await MacOSInstaller.firstBoot { _ = try await Start.launch(bundle, timeout: 120) }
        let proxy = SSHConfig.proxyCommand(macvmPath: SSHConfigCommand.executablePath, name: name, flags: ["--tcp", "--timeout", "600"])
        try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: pw, proxyCommand: proxy, timeout: 900)
        do {
            try await MacOSProvisioning.setHostNameAndTimeZone(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
        } catch {
            warn("设置主机名与时区失败：\((error as? MacVMError)?.message ?? error.localizedDescription)")
        }
        if AgentInstaller.binary(for: .macOS) != nil {
            _ = try await AgentInstaller.installAndEnable(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
        }
        // 调优失败不算安装失败，原因写到标准错误，可稍后单独运行 macvm tune。
        if !noTune {
            say("调优客户机…")
            do {
                let report = try await MacOSTuning.run(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
                say(Tune.render(name, report))
            } catch {
                warn("调优失败：\((error as? MacVMError)?.message ?? error.localizedDescription)，可稍后运行 macvm tune \(name)")
            }
        }
        say("macOS 已就绪：macvm ssh \(name)；用户 \(user)，密码见 \(GuestCredentials.passwordURL(bundle).path)")
        return try VMStatus.summary(of: bundle)
    }

    /// 不影响结果的问题：`--json` 时也写到标准错误。
    private func warn(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func createWindows() async throws -> VMSummary {
        guard installMedia.count <= 1 else { throw MacVMError.invalidConfig("Windows 只能用 --iso 指定一张安装 ISO") }

        let iso: URL
        if let path = installMedia.first {
            iso = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            say("正在从微软下载 Windows 11 ARM64 安装 ISO（语言随系统首选语言）…")
            iso = try await WindowsISO.iso(showProgress: interactive)
        }
        let options = WindowsInstaller.Options(
            name: name, iso: iso,
            virtioWin: virtioWin.map { URL(filePath: ($0 as NSString).expandingTildeInPath) },
            cpuCount: cpuCount, memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
            user: user ?? NSUserName(), password: password, productKey: productKey, showProgress: interactive
        )
        let bundle = try await WindowsInstaller.create(options)
        SSHConfigCommand.refresh()
        guard !noInstall else { return try VMStatus.summary(of: bundle) }

        say("开始安装 Windows（约 15–30 分钟，进度可用 macvm run \(name) --display 查看）…")
        _ = try await Start.launch(bundle, timeout: 120)
        let finished = try await WindowsInstaller.completeSetup(bundle, macvmPath: SSHConfigCommand.executablePath) {
            say("安装完成，正在关机并卸下安装介质…")
            _ = try ControlClient.send(.stop(force: false), to: bundle)
        }
        guard finished else { throw MacVMError.timeout("安装完成后客户机未关机") }
        say("Windows 已就绪：macvm exec \(name) -- whoami；密码见 \(GuestCredentials.passwordURL(bundle).path)")
        return try VMStatus.summary(of: bundle)
    }

    static func parseNetwork(_ text: String) throws -> NetworkConfig {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "nat": return NetworkConfig(mode: .nat)
        case "bridged": return NetworkConfig(mode: .bridged, interface: parts.count > 1 ? parts[1] : nil)
        default: throw MacVMError.invalidConfig("未知网络模式：\(text)（可选 nat、bridged[:网卡名]）")
        }
    }

    /// 没给 `--user` 时登录用户取主机用户名，它不一定满足 `GuestAccount.validate(user:)`，要在安装开始前报错。
    static func validateDefaultUser(_ user: String?) throws {
        guard user == nil else { return }
        do {
            try GuestAccount.validate(user: NSUserName())
        } catch {
            throw MacVMError.invalidConfig("主机用户名 \(NSUserName()) 不能用作客户机登录用户，请用 --user 指定")
        }
    }

    /// 把 `--share` 逐个交给 `VMConfig.addShare`：校验目录、名称长度与重名，缺省名称按客户机系统生成。
    static func shareConfigs(_ specs: [String], name: String, os: GuestOS, engine: Engine) throws -> [ShareConfig] {
        var config = VMConfig(name: name, os: os, engine: engine, cpuCount: 1, memorySize: 0, disks: [])
        for spec in try specs.map(parseShare) {
            try config.addShare(hostPath: spec.hostPath, tag: spec.tag, readOnly: spec.readOnly)
        }
        return config.shares
    }

    /// `主机路径[:tag][:ro]`；路径展开 `~` 并标准化，没写 tag 时为 nil。
    static func parseShare(_ text: String) throws -> (hostPath: String, tag: String?, readOnly: Bool) {
        var parts = text.split(separator: ":").map(String.init)
        guard let first = parts.first else { throw MacVMError.invalidConfig("共享目录参数为空") }
        let path = standardizedPath(first)
        parts.removeFirst()
        let readOnly = parts.last == "ro"
        if readOnly { parts.removeLast() }
        return (path, parts.first, readOnly)
    }

    static func standardizedPath(_ text: String) -> String {
        URL(filePath: (text as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

extension GuestOS: ExpressibleByArgument {}
extension Engine: ExpressibleByArgument {}
