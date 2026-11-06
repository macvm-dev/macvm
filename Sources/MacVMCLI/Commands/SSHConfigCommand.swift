import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct SSHConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-config",
        abstract: String(l10n: "Generate an ssh config so you can connect to each VM with `ssh <name>`."),
        discussion: String(l10n: """
        Writes the config to ~/.config/macvm/ssh_config; from then on, macvm create and macvm rm keep it up to date.
        With --install, also adds an Include line to the top of ~/.ssh/config so that ssh and other tools that read it (such as runode) can find these hosts.
        """)
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: ArgumentHelp(String(l10n: "Add an Include line to ~/.ssh/config.")))
    var install = false

    struct Result: Encodable, Sendable {
        let path: String
        let included: Bool
        let hosts: [String]
    }

    func run() async throws {
        try await Output.run(json: global.json, human: Self.render) {
            _ = try await SSHKeys.ensurePublicKey()
            let url = try SSHConfig.write(macvmPath: Self.executablePath)
            if install { try SSHConfig.installInclude() }
            let hosts = try VMLibrary.default.all().map(\.name)
            return Result(path: url.path, included: SSHConfig.isIncluded, hosts: hosts)
        }
    }

    static func render(_ r: Result) -> String {
        var lines = [String(l10n: "Wrote \(r.path)")]
        if !r.hosts.isEmpty { lines.append(String(l10n: "Hosts: \(r.hosts.joined(separator: " "))")) }
        if !r.included { lines.append(String(l10n: "~/.ssh/config doesn't include it yet. Run macvm ssh-config --install, or add this line yourself: \(SSHConfig.includeLine)")) }
        return lines.joined(separator: "\n")
    }

    static var executablePath: String {
        (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    /// 按当前虚拟机列表重写已启用的 ssh 配置。
    static func refresh() {
        SSHConfig.refreshIfInstalled(macvmPath: executablePath)
    }
}
