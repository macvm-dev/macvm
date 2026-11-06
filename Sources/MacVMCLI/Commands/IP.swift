import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct IP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: String(l10n: "Show the IP address of a VM."))

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Option(help: ArgumentHelp(String(l10n: "Seconds to wait for an IP address."))) var wait: Int = 0

    struct Result: Encodable, Sendable { let ipAddress: String }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.ipAddress }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            guard let ip = try await VMStatus.waitForIPAddress(bundle, timeout: TimeInterval(wait), interval: 1) else {
                throw BundleLock.holder(of: bundle) == nil ? MacVMError.notRunning(name) : MacVMError.timeout(String(l10n: "Couldn't get the IP address of \(name)"))
            }
            return Result(ipAddress: ip)
        }
    }
}
