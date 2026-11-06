import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Wait until a VM is ready: its guest agent responds, or, without an agent, its SSH port accepts connections."),
        discussion: String(l10n: "Starts the VM in the background if it isn't running.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait before giving up."))) var timeout: Int = 120

    func run() async throws {
        try await Output.run(json: global.json, human: { (_: VMSummary) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            try await Self.untilReady(bundle, config: bundle.loadConfig(), timeout: timeout)
            return try VMStatus.summary(of: bundle)
        }
    }

    static func untilReady(_ bundle: VMBundle, config: VMConfig, timeout: Int) async throws {
        if BundleLock.holder(of: bundle) == nil {
            _ = try await Start.launch(bundle, timeout: timeout)
        }
        if config.guestAgent {
            let ready = try await VMStatus.poll(timeout: TimeInterval(timeout), interval: 0.2) { AgentClient.isReachable(bundle) }
            guard ready else { throw MacVMError.timeout(String(l10n: "The guest agent on \(bundle.name) didn't respond within \(timeout) seconds")) }
        } else {
            close(try await Proxy.openWithRetry(bundle, config: config, port: 22, timeout: timeout))
        }
    }
}
