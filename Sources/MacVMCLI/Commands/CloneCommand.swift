import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "克隆一台已停止的虚拟机。",
        discussion: "APFS 上零拷贝，秒级完成；新虚拟机获得新的机器标识与 MAC，云镜像虚拟机会以新主机名重新初始化。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "源虚拟机。") var source: String
    @Argument(help: "新虚拟机名称。") var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "已克隆为 \(s.name)" }) {
            let bundle = try await VMClone.clone(VMLibrary.default.bundle(named: source), as: name)
            SSHConfigCommand.refresh()
            return try VMStatus.summary(of: bundle)
        }
    }
}
