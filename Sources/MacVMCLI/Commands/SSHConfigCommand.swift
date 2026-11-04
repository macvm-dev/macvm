import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct SSHConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-config",
        abstract: "生成 ssh 配置，让每台虚拟机可用 `ssh <名>` 连接。",
        discussion: """
        配置写到 ~/.config/macvm/ssh_config，此后 create / rm 会自动更新它。
        --install 在 ~/.ssh/config 开头加入 Include，ssh 与读取 ssh 配置的工具（如 runode）即可看到这些主机。
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "在 ~/.ssh/config 中加入 Include。")
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
        var lines = ["已写入 \(r.path)"]
        if !r.hosts.isEmpty { lines.append("主机：" + r.hosts.joined(separator: " ")) }
        if !r.included { lines.append("尚未被 ~/.ssh/config 引用，运行 macvm ssh-config --install 或手动加一行：\(SSHConfig.includeLine)") }
        return lines.joined(separator: "\n")
    }

    static var executablePath: String {
        (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    /// create / rm 之后调用，保持已启用的 ssh 配置与虚拟机列表一致。
    static func refresh() {
        SSHConfig.refreshIfInstalled(macvmPath: executablePath)
    }
}
