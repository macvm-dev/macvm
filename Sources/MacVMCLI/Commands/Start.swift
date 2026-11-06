import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Start a VM in the background and wait until it's running."),
        discussion: String(l10n: "The background process logs to run.log inside the VM bundle.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait for the VM to start.")))
    var timeout: Int = 60

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in String(l10n: "\(s.name) is running in the background (pid \(s.pid.map(String.init) ?? "?"))") }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(name) }
            return try await Self.launch(bundle, timeout: timeout)
        }
    }

    /// 用本 CLI 派生后台进程。
    static func launch(_ bundle: VMBundle, timeout: Int) async throws -> VMSummary {
        try bundle.requireNotCreating()
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return try await DetachedRun.launch(bundle, executable: executable, timeout: timeout)
    }
}
