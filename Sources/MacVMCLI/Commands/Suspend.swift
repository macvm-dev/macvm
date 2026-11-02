import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Suspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "挂起虚拟机：把内存状态存盘后停止，下次 start 从此处继续。",
        discussion: "Windows 客户机与带 USB 直通等设备的配置不支持挂起。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Option(help: "等待存盘完成的最长秒数。")
    var timeout: Int = 300

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in "\(name) 已挂起" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            _ = try ControlClient.check(ControlClient.send(.suspend, to: bundle, timeout: timeout), bundle: bundle)
            let stopped = try await VMStatus.poll(timeout: 30) { BundleLock.holder(of: bundle) == nil }
            guard stopped else { throw MacVMError.timeout("挂起后进程未退出") }
            return Empty()
        }
    }
}
