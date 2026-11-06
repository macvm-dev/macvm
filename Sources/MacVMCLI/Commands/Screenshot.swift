import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: String(l10n: "Save a running VM's screen as a PNG (QEMU engine only)."))

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Argument(help: ArgumentHelp(String(l10n: "Path to save the PNG to."))) var output: String

    struct Result: Encodable, Sendable { let path: String }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.path }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let url = URL(filePath: (output as NSString).expandingTildeInPath).standardizedFileURL
            try ControlClient.perform(.screenshot(path: url.path), on: bundle)
            return Result(path: url.path)
        }
    }
}
