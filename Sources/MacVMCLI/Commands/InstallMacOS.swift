import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct InstallMacOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-macos",
        abstract: "从 IPSW 创建并安装 macOS 虚拟机。",
        discussion: """
        不指定 --ipsw 时下载本机支持的最新版本（约 15–20 GB，缓存在 ~/Library/Caches/MacVM/ipsw）。
        安装后首次开机自动创建用户、自动登录并开启 SSH，再装入 macvm 专用密钥，之后可直接 macvm ssh / exec。
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Option(help: "本地 IPSW 文件。") var ipsw: String?
    @Option(name: .customLong("cpus"), help: "vCPU 数。") var cpuCount: Int?
    @Option(help: "内存，如 8G。") var memory: String?
    @Option(help: "磁盘容量（稀疏），如 96G。") var disk: String?
    @Option(help: "客户机用户名，默认与主机用户同名。") var user: String = NSUserName()
    @Option(help: "客户机密码，默认随机生成，保存在虚拟机包内的 guest-password。") var password: String?
    @Option(help: "显示分辨率，如 1920x1200。") var resolution: String = "1920x1200"
    @Flag(help: "安装完不开机配置 SSH。") var noProvision = false

    struct Result: Encodable, Sendable {
        let vm: VMSummary
        let user: String
        let passwordFile: String
        let sshReady: Bool
    }

    @MainActor
    func run() async throws {
        try await Output.run(json: global.json, human: Self.render) {
            let parts = resolution.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw MacVMError.invalidConfig("分辨率格式应为 宽x高：\(resolution)") }
            let interactive = !global.json && isatty(STDERR_FILENO) == 1
            let options = MacOSInstaller.Options(
                name: name,
                source: ipsw.map { .file(URL(filePath: ($0 as NSString).expandingTildeInPath)) } ?? .latest,
                cpuCount: cpuCount, memorySize: try memory.map(ByteSize.parse), diskSize: try disk.map(ByteSize.parse),
                user: user, password: password,
                display: DisplayConfig(width: parts[0], height: parts[1], pixelsPerInch: 144),
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

            var sshReady = false
            if !noProvision, let pw = MacOSProvisioning.password(for: bundle) {
                if interactive { FileHandle.standardError.write(Data("首次开机并配置 SSH（可能需要几分钟）…\n".utf8)) }
                _ = try await Start.launch(bundle, timeout: 120)
                let proxy = "\"\(SSHConfigCommand.executablePath)\" proxy \(name) --tcp --timeout 600"
                try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: pw, proxyCommand: proxy, timeout: 900)
                sshReady = true
                var config = try bundle.loadConfig()
                if AgentInstaller.binary(for: .macOS) != nil {
                    try await AgentInstaller.installOverSSH(bundle: bundle, config: config, macvmPath: SSHConfigCommand.executablePath)
                    if try await VMStatus.poll(timeout: 30, interval: 0.3, { AgentClient.isReachable(bundle) }) {
                        config.guestAgent = true
                        try bundle.saveConfig(config)
                    }
                }
            }
            return Result(vm: try VMStatus.summary(of: bundle), user: user,
                          passwordFile: MacOSProvisioning.passwordURL(bundle).path, sshReady: sshReady)
        }
    }

    static func render(_ r: Result) -> String {
        """
        已安装 \(r.vm.name)（\(r.vm.state.rawValue)）
        用户 \(r.user)，密码见 \(r.passwordFile)
        \(r.sshReady ? "SSH 已就绪：macvm ssh \(r.vm.name)" : "首次开机后自动登录并开启 SSH")
        """
    }
}
