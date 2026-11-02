import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "等到虚拟机可用：装有代理时等代理响应，否则等 SSH 端口可连。",
        discussion: "虚拟机未运行时自动在后台启动。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "最长等待秒数。") var timeout: Int = 120

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: VMSummary) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try await Self.untilReady(bundle, config: bundle.loadConfig(), timeout: timeout)
            return try VMStatus.summary(of: bundle)
        }
    }

    static func untilReady(_ bundle: VMBundle, config: VMConfig, timeout: Int) async throws {
        if BundleLock.holder(of: bundle) == nil {
            _ = try await Start.launch(bundle, timeout: timeout)
        }
        if config.guestAgent {
            let ready = try await VMStatus.poll(timeout: TimeInterval(timeout), interval: 0.2) { AgentClient.isReachable(bundle) }
            guard ready else { throw MacVMError.timeout("\(bundle.name) 的客户机代理 \(timeout) 秒内未响应") }
        } else {
            let fd = try await GuestConnection.connect(to: bundle, port: 22, timeout: TimeInterval(timeout))
            close(fd)
        }
    }
}
