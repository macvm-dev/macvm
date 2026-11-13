public import ArgumentParser
import Foundation
import MacVMEngine
public import MacVMModel

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Create a VM."),
        discussion: String(l10n: """
        macOS: installs from an IPSW. Without --ipsw, downloads the latest version this Mac supports (about 15–20 GB, cached under ipsw in the downloads folder). On first boot it creates a user,
        turns on automatic login and SSH, installs the macvm SSH key and the guest agent, sets the hostname to the VM name, and runs every macvm tune step (skip with --no-tune).
          macvm create mac --os macos
        Windows 11 ARM64: installs unattended from an official ISO using the QEMU engine (requires brew install qemu) and sets up a user and OpenSSH.
          macvm create win --os windows --iso ~/Downloads/Win11_arm64.iso
        Linux cloud images (recommended): pick one with --image; it's downloaded and cached on first use. The VM boots with a user and the macvm SSH key already set up.
          macvm create dev --image debian-13 --memory 8G
        Linux desktop: --desktop downloads the distribution's desktop installer ISO (checked with SHA-256 and cached). Ubuntu installs offline and unattended by default, with a user and the SSH public key set up;
        add --manual-install to use the graphical installer instead. Fedora boots into the graphical installer in the window, where you finish the setup.
          macvm create desk --desktop ubuntu-desktop
        Installation media: creates an empty disk and boots the installer from the media given with --iso (Linux, Windows).
          macvm create box --os linux --iso ~/Downloads/fedora-aarch64.iso
        Templates: copies a template saved with macvm template save (any OS, including macOS). You can also pass --cpus, --memory, --disk (grow only), and --engine.
          macvm create dev2 --template dev-base
        """)
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: ArgumentHelp(String(l10n: "VM name (letters, digits, . _ -, up to 40 characters).")))
    var name: String

    @Option(name: .customLong("os"), help: ArgumentHelp(String(l10n: "Guest OS: linux (default), windows, or macos.")))
    var osOption: GuestOS?

    var os: GuestOS { osOption ?? .linux }

    @Option(help: ArgumentHelp(String(l10n: "Create from a template (see macvm template).")))
    var template: String?

    @Option(name: .customLong("cpus"), help: ArgumentHelp(String(l10n: "Number of vCPUs (default 4, at most the host's core count).")))
    var cpuCount: Int?

    @Option(help: ArgumentHelp(String(l10n: "Memory size, e.g. 4G (default 8G, at most half the host's memory).")))
    var memory: String?

    @Option(help: ArgumentHelp(String(l10n: "Disk size, e.g. 64G. The disk is sparse and only uses space for data actually written.")))
    var disk: String?

    @Option(help: ArgumentHelp(String(l10n: "Linux cloud image."), valueName: LinuxImage.catalog.map(\.id).joined(separator: "|")))
    var image: String?

    @Option(help: ArgumentHelp(String(l10n: "Linux desktop: download the official installer ISO and boot from it. Ubuntu installs automatically; Fedora uses the graphical installer in the window."), valueName: LinuxDesktop.allCases.map(\.rawValue).joined(separator: "|")))
    var desktop: String?

    @Flag(help: ArgumentHelp(String(l10n: "Ubuntu Desktop: use the graphical installer in the window instead of installing automatically.")))
    var manualInstall = false

    @Option(help: ArgumentHelp(String(l10n: "Login user to create for cloud images, automatically installed Ubuntu Desktop, and Windows (default: your host user name).")))
    var user: String?

    @Option(help: ArgumentHelp(String(l10n: "Login password for cloud images, automatically installed Ubuntu Desktop, and Windows, saved as guest-password in the VM bundle. If omitted, cloud images allow only SSH key login, and Ubuntu Desktop and Windows get a random password.")))
    var password: String?

    @Option(name: .customLong("iso"), help: ArgumentHelp(String(l10n: "Installation media to attach as a read-only USB drive (repeatable). Windows takes only one, and downloads it from Microsoft if omitted.")))
    var installMedia: [String] = []

    @Option(help: ArgumentHelp(String(l10n: "Shared folder as host-path[:tag][:ro] (repeatable).")))
    var share: [String] = []

    @Flag(help: ArgumentHelp(String(l10n: "Linux: enable Rosetta to run x86_64 programs.")))
    var rosetta = false

    @Flag(inversion: .prefixedNo, help: ArgumentHelp(String(l10n: "Run without a keyboard or mouse (SSH only), which allows suspending. On by default for cloud images, off for installation media.")))
    var headless: Bool?

    @Option(help: ArgumentHelp(String(l10n: "Windows: virtio-win driver ISO; downloaded and cached if omitted.")))
    var virtioWin: String?

    @Option(help: ArgumentHelp(String(l10n: "Virtualization engine: vz (default, lowest overhead) or qemu (more features). Windows always installs with qemu.")))
    var engine: Engine?

    @Option(name: .customLong("product-key"), help: ArgumentHelp(String(l10n: "Windows: product key to activate online after installation; it isn't saved in the VM configuration. If omitted, Windows isn't activated.")))
    var productKey: String?

    @Flag(help: ArgumentHelp(String(l10n: "Windows: create the VM but don't start installing yet.")))
    var noInstall = false

    @Flag(help: ArgumentHelp(String(l10n: "Write the guest console output to run.log when running in the background.")))
    var console = false

    @Option(help: ArgumentHelp(String(l10n: "macOS: local IPSW file (default: download the latest version this Mac supports).")))
    var ipsw: String?

    @Option(help: ArgumentHelp(String(l10n: "macOS: display resolution (default 1920x1200).")))
    var resolution: String?

    @Flag(help: ArgumentHelp(String(l10n: "macOS: skip the first boot that sets up SSH, the guest agent, and tuning.")))
    var noProvision = false

    @Flag(help: ArgumentHelp(String(l10n: "macOS: don't run macvm tune after setup.")))
    var noTune = false

    @Option(help: ArgumentHelp(String(l10n: "Forward a host TCP port to the guest as [address:]host-port:guest-port (repeatable); see macvm set.")))
    var forward: [String] = []

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in String(l10n: "Created \(s.name): \(s.path)") }) {
            // 先校验，免得装完才报错。
            let forwards = try PortForward.parseAll(forward)
            let summary = try await create()
            guard !forwards.isEmpty else { return summary }
            let bundle = try VMLibrary.default.bundle(named: summary.name)
            try bundle.updateConfig { $0.forwards = forwards }
            // 虚拟机已经建好，转发监听失败只警告，不让 create 报失败。
            if BundleLock.holder(of: bundle) != nil {
                do { try ControlClient.applyForwards(bundle) } catch {
                    let message = (error as? MacVMError)?.message ?? error.localizedDescription
                    FileHandle.standardError.write(Data("macvm: \(message)\n".utf8))
                }
            }
            return try VMStatus.summary(of: bundle)
        }
    }

    private func create() async throws -> VMSummary {
        if let template { return try await createFromTemplate(template) }
        if let user { try GuestAccount.validate(user: user) }
        if let password { try GuestAccount.validate(password: password) }
        if os == .macOS { return try await createMacOS() }
        let macOnly: [(String, Bool)] = [
            ("--ipsw", ipsw != nil), ("--resolution", resolution != nil), ("--no-provision", noProvision), ("--no-tune", noTune),
        ]
        if let option = macOnly.first(where: \.1)?.0 { throw MacVMError.invalidConfig(String(l10n: "\(option) is only for macOS guests")) }
        if os == .windows {
            if image != nil || desktop != nil { throw MacVMError.invalidConfig(String(l10n: "--image and --desktop are only for Linux guests")) }
            let ignored: [(String, Bool)] = [
                ("--share", !share.isEmpty), ("--rosetta", rosetta), ("--headless", headless != nil),
                ("--console", console), ("--manual-install", manualInstall),
            ]
            if let option = ignored.first(where: \.1)?.0 { throw MacVMError.invalidConfig(String(l10n: "\(option) doesn't apply to Windows guests")) }
            try Self.validateDefaultUser(user)
            return try await createWindows()
        }
        if productKey != nil { throw MacVMError.invalidConfig(String(l10n: "--product-key is only for Windows")) }
        let desktop = try desktop.map(LinuxDesktop.named)
        if manualInstall, desktop?.supportsUnattended != true {
            throw MacVMError.invalidConfig(String(l10n: "--manual-install only works with desktops that install automatically (--desktop ubuntu-desktop)"))
        }
        if engine == .qemu { _ = try QEMUInstallation.require() }
        let options = VMFactory.Options(
            name: name, os: os, cpuCount: cpuCount,
            memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
            installMedia: installMedia,
            shares: try Self.shareConfigs(share, name: name, os: os, engine: engine ?? .vz), rosetta: rosetta, serialConsole: console,
            image: try image.map(LinuxImage.named), desktop: desktop, unattended: !manualInstall, user: user ?? NSUserName(), password: password,
            showProgress: interactive, headless: headless
        )
        if password != nil, image == nil, !options.autoinstalls {
            throw MacVMError.invalidConfig(String(l10n: "--password is only for Linux cloud images (--image), the automatically installed Ubuntu Desktop, and Windows"))
        }
        if image != nil || options.autoinstalls { try Self.validateDefaultUser(user) }
        let bundle = try await VMFactory.createEFIGuest(options)
        if let engine, engine != .vz {
            try bundle.updateConfig { $0.engine = engine }
        }
        SSHConfigCommand.refresh()
        if options.autoinstalls { try await installUbuntu(bundle) }
        return try VMStatus.summary(of: bundle)
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
            throw MacVMError.invalidConfig(String(l10n: "\(option) can't be used with --template: the OS, accounts, and devices all come from the template"))
        }
        let template = try TemplateLibrary.default.template(named: name)
        if let osOption, osOption != (try template.loadConfig()).os {
            throw MacVMError.invalidConfig(String(l10n: "Template \(name) isn't a \(osOption.rawValue) guest"))
        }
        let bundle = try await VMTemplate.instantiate(
            template, as: self.name, cpuCount: cpuCount, memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse)
        ) { config in
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
        say(String(l10n: "Installing Ubuntu offline…"))
        _ = try await Start.launch(bundle, timeout: 120)
        try await UbuntuAutoinstall.completeSetup(bundle) {
            _ = try await Start.launch(bundle, timeout: 120)
        }
        say(String(l10n: "Ubuntu is ready: macvm exec \(name) -- whoami (password in \(GuestCredentials.passwordURL(bundle).path))"))
    }

    /// 网络与共享目录不在安装时设置：首次开机经 NAT 下的客户机 IP 开通 SSH，装好后用 `macvm set` 改。
    @MainActor
    private func createMacOS() async throws -> VMSummary {
        let unsupported: [(String, Bool)] = [
            ("--image", image != nil), ("--desktop", desktop != nil), ("--manual-install", manualInstall), ("--iso", !installMedia.isEmpty),
            ("--rosetta", rosetta), ("--headless", headless != nil), ("--virtio-win", virtioWin != nil),
            ("--product-key", productKey != nil), ("--no-install", noInstall), ("--console", console), ("--engine qemu", engine == .qemu),
        ]
        if let option = unsupported.first(where: \.1)?.0 { throw MacVMError.invalidConfig(String(l10n: "\(option) doesn't apply to macOS guests")) }
        if !share.isEmpty { throw MacVMError.invalidConfig(String(l10n: "macOS installs without shared folders; add them afterward with macvm set --add-share")) }
        try Self.validateDefaultUser(user)
        let user = user ?? NSUserName()
        let resolution = resolution ?? "1920x1200"
        guard let (width, height) = Display.parse(resolution) else {
            throw MacVMError.invalidConfig(String(l10n: "Invalid resolution \(resolution); use WIDTHxHEIGHT"))
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
            case .downloading: FileHandle.standardError.write(Data((String(l10n: "Downloading the IPSW…") + "\n").utf8))
            case .installing(let f):
                let percent = Int(f * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    FileHandle.standardError.write(Data(("\r" + String(l10n: "Installing macOS: \(percent)%")).utf8))
                }
            }
        }
        if interactive { FileHandle.standardError.write(Data("\n".utf8)) }
        SSHConfigCommand.refresh()
        guard !noProvision, let pw = GuestCredentials.password(for: bundle) else { return try VMStatus.summary(of: bundle) }

        say(String(l10n: "Starting the VM for the first time to set up SSH (this can take a few minutes)…"))
        try await MacOSInstaller.firstBoot { _ = try await Start.launch(bundle, timeout: 120) }
        let proxy = SSHConfig.proxyCommand(macvmPath: SSHConfigCommand.executablePath, name: name, flags: ["--tcp", "--timeout", "600"])
        try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: pw, proxyCommand: proxy, timeout: 900)
        do {
            try await MacOSProvisioning.setHostNameAndTimeZone(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
        } catch {
            warn(String(l10n: "Couldn't set the hostname and time zone: \((error as? MacVMError)?.message ?? error.localizedDescription)"))
        }
        if AgentInstaller.binary(for: .macOS) != nil {
            _ = try await AgentInstaller.installAndEnable(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
        }
        // 调优失败不算安装失败，原因写到标准错误，可稍后单独运行 macvm tune。
        if !noTune {
            say(String(l10n: "Tuning the guest…"))
            do {
                let report = try await MacOSTuning.run(bundle: bundle, config: bundle.loadConfig(), macvmPath: SSHConfigCommand.executablePath)
                say(Tune.render(name, report))
            } catch {
                warn(String(l10n: "Couldn't tune the guest: \((error as? MacVMError)?.message ?? error.localizedDescription); you can run macvm tune \(name) later"))
            }
        }
        say(String(l10n: "macOS is ready: macvm ssh \(name) (user \(user), password in \(GuestCredentials.passwordURL(bundle).path))"))
        return try VMStatus.summary(of: bundle)
    }

    /// 不影响结果的问题：`--json` 时也写到标准错误。
    private func warn(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func createWindows() async throws -> VMSummary {
        guard installMedia.count <= 1 else { throw MacVMError.invalidConfig(String(l10n: "Windows accepts only one --iso")) }

        let iso: URL
        if let path = installMedia.first {
            iso = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            say(String(l10n: "Downloading the Windows 11 ARM64 ISO from Microsoft in your system's language…"))
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

        say(String(l10n: "Installing Windows (about 15–30 minutes; watch the progress with macvm run \(name) --display)…"))
        _ = try await Start.launch(bundle, timeout: 120)
        let finished = try await WindowsInstaller.completeSetup(bundle, macvmPath: SSHConfigCommand.executablePath) {
            say(String(l10n: "Installation finished; shutting down and removing the installation media…"))
            _ = try ControlClient.send(.stop(force: false), to: bundle)
        } start: {
            say(String(l10n: "Restarting…"))
            _ = try await Start.launch(bundle, timeout: 120)
        }
        guard finished else { throw MacVMError.timeout(String(l10n: "The guest didn't shut down after the installation finished")) }
        say(String(l10n: "Windows is ready: macvm exec \(name) -- whoami (password in \(GuestCredentials.passwordURL(bundle).path))"))
        return try VMStatus.summary(of: bundle)
    }

    /// 没给 `--user` 时登录用户取主机用户名，它不一定满足 `GuestAccount.validate(user:)`，要在安装开始前报错。
    static func validateDefaultUser(_ user: String?) throws {
        guard user == nil else { return }
        do {
            try GuestAccount.validate(user: NSUserName())
        } catch {
            throw MacVMError.invalidConfig(String(l10n: "Your host user name \(NSUserName()) can't be used as the guest login user; choose one with --user"))
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
        guard let first = parts.first else { throw MacVMError.invalidConfig(String(l10n: "The shared folder path is empty")) }
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
