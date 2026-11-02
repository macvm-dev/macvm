import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "管理客户机代理（macvm-agent）。",
        discussion: "代理经 vsock 提供 exec、端口转发、关机、对时与剪贴板，不依赖客户机网络。云镜像与 install-macos 创建的虚拟机自动安装。",
        subcommands: [Install.self, Info.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "经 SSH 安装或更新代理。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: AgentProtocol.Info) in "已安装 \(name) 的客户机代理" }) {
                let bundle = try VMLibrary.default.bundle(named: name)
                var config = try bundle.loadConfig()
                var probe = config
                probe.guestAgent = false
                try await Wait.untilReady(bundle, config: probe, timeout: 300)
                try await AgentInstaller.installOverSSH(bundle: bundle, config: config, macvmPath: SSHConfigCommand.executablePath)
                guard try await VMStatus.poll(timeout: 30, interval: 0.3, { AgentClient.isReachable(bundle) }) else {
                    throw MacVMError.timeout("代理已安装但未响应")
                }
                config.guestAgent = true
                try bundle.saveConfig(config)
                return try AgentClient.info(bundle)
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "显示代理报告的客户机信息。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try AgentClient.info(VMLibrary.default.bundle(named: name))
            }
        }

        static func render(_ i: AgentProtocol.Info) -> String {
            """
            代理 \(i.version) · \(i.os) · \(i.hostname)
            IPv4：\(i.ipv4.joined(separator: ", "))
            内存：可用 \(ByteSize.format(i.memAvailable)) / \(ByteSize.format(i.memTotal))
            运行：\(i.uptimeMs / 1000) 秒
            """
        }
    }
}
