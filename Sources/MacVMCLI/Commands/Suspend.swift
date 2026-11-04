import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Suspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "挂起虚拟机：把内存状态存盘后停止，下次 start 从此处继续。",
        discussion: "VZ 引擎下的 Windows 与非 headless 的 Linux 客户机、挂着安装介质的虚拟机，以及带 USB 直通等设备的配置不支持挂起。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Option(help: "等待存盘完成的最长秒数。")
    var timeout: Int = 300

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in "\(name) 已挂起" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try ControlClient.perform(.suspend, on: bundle, timeout: timeout)
            guard try await VMStatus.waitUntilStopped(bundle, timeout: 30) else { throw MacVMError.timeout("挂起后进程未退出") }
            return Empty()
        }
    }
}
