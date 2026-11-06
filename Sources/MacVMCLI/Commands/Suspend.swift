import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Suspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Suspend a VM, saving its memory to disk so the next start resumes where it left off."),
        discussion: String(l10n: "Not available for Windows guests or non-headless Linux guests on the VZ engine, for VMs with installation media attached, or for VMs using devices such as USB passthrough.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait for the state to be saved.")))
    var timeout: Int = 300

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "\(name) suspended") }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try ControlClient.perform(.suspend, on: bundle, timeout: timeout)
            guard try await VMStatus.waitUntilStopped(bundle, timeout: 30) else { throw MacVMError.timeout(String(l10n: "The VM process didn't exit after suspending")) }
            return Empty()
        }
    }
}
