import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: String(l10n: "Show the status of a VM."))

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { List.table([$0]) }) {
            try VMStatus.summary(of: VMLibrary.default.bundle(named: name))
        }
    }
}
