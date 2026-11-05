import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "管理客户机代理（macvm-agent）。",
        discussion: "代理提供 exec、端口转发、关机、对时、剪贴板与 UI 自动化（macvm ui）。VZ 下的 Linux、macOS 经 vsock，不依赖客户机网络；Windows 与 QEMU 下的 Linux 经 TCP。云镜像、macOS、自动安装的 Ubuntu 桌面版与 Windows 安装创建的虚拟机自动安装。",
        subcommands: [Install.self, Info.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "安装或更新代理。",
            discussion: "代理在线时经代理自身换成随 App 分发的版本，不需要 SSH；没装代理、代理不在线、要补写认证令牌或给 Windows 放 3D 显卡驱动，以及给了 --ssh 时经 SSH 安装。"
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Flag(help: "经 SSH 安装，即使代理在线。") var ssh = false

        func run() async throws {
            var gpuDriver = false
            var updated: AgentUpdate.Result?
            try await Output.run(json: global.json, human: { (_: InfoResult) in
                if let updated {
                    guard updated.changed else { return "\(name) 的客户机代理已是 App 自带的版本；要重装请加 --ssh" }
                    return "已更新 \(name) 的客户机代理" + (updated.rebooting ? "；3D 显卡驱动也已更新，正在重启客户机" : "")
                }
                return "已安装 \(name) 的客户机代理" + (gpuDriver ? "；3D 显卡驱动已放进客户机，代理随即安装，重启客户机后桌面改用 GPU 合成" : "")
            }) {
                let bundle = try VMLibrary.default.bundle(named: name)
                let config = try bundle.loadConfig()
                if !ssh, config.guestAgent, AgentUpdate.coversInstall(bundle, config: config), AgentClient.isReachable(bundle) {
                    updated = try await AgentUpdate.update(bundle)
                    return try InfoResult(bundle)
                }
                var probe = config
                probe.guestAgent = false
                try await Wait.untilReady(bundle, config: probe, timeout: 300)
                let result = try await AgentInstaller.installAndEnable(bundle: bundle, config: config, macvmPath: SSHConfigCommand.executablePath)
                gpuDriver = result.gpuDriver
                guard result.online else { throw MacVMError.timeout("代理已安装但未响应") }
                return try InfoResult(bundle)
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "显示代理报告的客户机信息。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try InfoResult(VMLibrary.default.bundle(named: name))
            }
        }

        static func render(_ r: InfoResult) -> String {
            render(r.info) + (r.updateAvailable == true ? "\n随 App 分发的代理版本不同，运行 macvm agent install \(r.name) 更新" : "")
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

    /// 代理报告的信息，外加它是否与随 App 分发的代理不同；无从比对时省略 `updateAvailable`。
    struct InfoResult: Encodable {
        let name: String
        let info: AgentProtocol.Info
        let updateAvailable: Bool?

        init(_ bundle: VMBundle) throws {
            name = bundle.name
            info = try AgentClient.info(bundle)
            updateAvailable = switch AgentUpdate.status(of: info, os: try bundle.loadConfig().os) {
            case .current: false
            case .outdated: true
            case .unknown: nil
            }
        }

        private enum Keys: String, CodingKey { case updateAvailable }

        func encode(to encoder: any Encoder) throws {
            try info.encode(to: encoder)
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(updateAvailable, forKey: .updateAvailable)
        }
    }
}
