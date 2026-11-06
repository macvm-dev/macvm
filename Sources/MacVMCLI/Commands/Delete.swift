import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: String(l10n: "Delete a VM and its disks."))

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "Deleted \(name)") }) {
            try VMFactory.delete(VMLibrary.default.bundle(named: name))
            SSHConfigCommand.refresh()
            return Empty()
        }
    }
}
