import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "删除虚拟机及其磁盘。")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in "已删除 \(name)" }) {
            try VMFactory.delete(VMLibrary.default.bundle(named: name))
            SSHConfigCommand.refresh()
            return Empty()
        }
    }
}
