import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Proxy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把标准输入输出接到客户机的 TCP 端口，供 ssh 的 ProxyCommand 使用。",
        discussion: "虚拟机未运行时自动在后台启动。"
    )

    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "客户机端口。") var port: UInt16 = 22
    @Option(help: "等待客户机就绪的最长秒数。") var timeout: Int = 120
    @Flag(help: "不经客户机代理，直连客户机 IP（代理尚未安装时使用）。") var tcp = false

    func run() async throws {
        try await Output.run(json: false, human: { (_: Empty) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) == nil {
                _ = try await Start.launch(bundle, timeout: timeout)
            }
            let config = try bundle.loadConfig()
            if config.guestAgent, !tcp {
                try await Wait.untilReady(bundle, config: config, timeout: timeout)
                try AgentClient.forward(bundle, port: port).pumpStandardIO()
            } else {
                let fd = try await GuestConnection.connect(to: bundle, port: port, timeout: TimeInterval(timeout))
                GuestConnection.pump((STDIN_FILENO, STDOUT_FILENO), fd)
                close(fd)
            }
            return Empty()
        }
    }
}
