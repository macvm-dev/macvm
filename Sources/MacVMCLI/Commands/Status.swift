import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "显示一台虚拟机的状态。")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { List.table([$0]) }) {
            try VMStatus.summary(of: VMLibrary.default.bundle(named: name))
        }
    }
}
