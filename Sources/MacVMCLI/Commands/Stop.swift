import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Shut down a VM."),
        discussion: String(l10n: "Asks the guest to shut down and waits for it. With --force, powers the VM off immediately, and any unsaved data is lost.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    @Flag(help: ArgumentHelp(String(l10n: "Power off immediately.")))
    var force = false

    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait for the guest to shut down.")))
    var timeout: Int = 90

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "\(name) stopped") }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try ControlClient.perform(.stop(force: force), on: bundle)
            guard try await VMStatus.waitUntilStopped(bundle, timeout: TimeInterval(timeout)) else {
                let apps = await Task.detached { GuestShutdown.blockingApps(bundle, waited: TimeInterval(timeout)) }.value
                guard !apps.isEmpty else { throw MacVMError.timeout(String(l10n: "The guest didn't shut down within \(timeout) seconds; use --force to power it off")) }
                let names = apps.map(\.name).formatted(.list(type: .and))
                throw DetailedError(
                    error: .timeout(String(l10n: "The guest didn't shut down within \(timeout) seconds. These apps in the guest haven't quit and may be blocking it: \(names). Quit them in the guest and try again, or use --force to power it off")),
                    blockingApps: apps
                )
            }
            return Empty()
        }
    }
}
