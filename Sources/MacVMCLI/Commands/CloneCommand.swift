import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: String(l10n: "Clone a stopped VM."),
        discussion: String(l10n: "On APFS nothing is actually copied, so cloning takes seconds. The clone gets a new machine identifier and MAC address, and if the VM was created from a cloud image, the clone is re-initialized with a new hostname.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM to clone."))) var source: String
    @Argument(help: ArgumentHelp(String(l10n: "Name of the new VM."))) var name: String

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in String(l10n: "Cloned as \(s.name)") }) {
            let bundle = try await VMClone.clone(VMLibrary.default.bundle(named: source), as: name)
            SSHConfigCommand.refresh()
            return try VMStatus.summary(of: bundle)
        }
    }
}
