import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "管理客户机代理（macvm-agent）。",
        discussion: "代理提供 exec、端口转发、关机、对时与剪贴板。Linux、macOS 上经 vsock，不依赖客户机网络；Windows 上经 TCP。云镜像、install-macos 与 Windows 安装创建的虚拟机自动安装。",
        subcommands: [Install.self, Info.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "经 SSH 安装或更新代理。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String

        func run() async throws {
            var gpuDriver = false
            try await Output.run(json: global.json, human: { (_: AgentProtocol.Info) in
                "已安装 \(name) 的客户机代理" + (gpuDriver ? "；3D 显卡驱动已放进客户机，代理随即安装，重启客户机后桌面改用 GPU 合成" : "")
            }) {
                let bundle = try VMLibrary.default.bundle(named: name)
                let config = try bundle.loadConfig()
                var probe = config
                probe.guestAgent = false
                try await Wait.untilReady(bundle, config: probe, timeout: 300)
                let result = try await AgentInstaller.installAndEnable(bundle: bundle, config: config, macvmPath: SSHConfigCommand.executablePath)
                gpuDriver = result.gpuDriver
                guard result.online else { throw MacVMError.timeout("代理已安装但未响应") }
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
