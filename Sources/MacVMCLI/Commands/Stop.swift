import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "关闭虚拟机。",
        discussion: "默认请求客户机自行关机并等待；--force 立即断电，未写回的数据会丢失。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Flag(help: "立即断电。")
    var force = false

    @Option(help: "等待客户机关机的最长秒数。")
    var timeout: Int = 90

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in "\(name) 已停止" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try ControlClient.perform(.stop(force: force), on: bundle)
            guard try await VMStatus.waitUntilStopped(bundle, timeout: TimeInterval(timeout)) else { throw MacVMError.timeout("客户机 \(timeout) 秒内未关机，可用 --force 断电") }
            return Empty()
        }
    }
}
