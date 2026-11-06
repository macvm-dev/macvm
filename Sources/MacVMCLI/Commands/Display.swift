import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Display: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Resize a running VM's display (VZ engine or the bundled QEMU)."),
        discussion: String(l10n: "The new size lasts until the VM shuts down. Omit the size to go back to the default, which you can change with macvm set --display. Windows on VZ has a fixed resolution and can't be resized.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Argument(help: ArgumentHelp(String(l10n: "Size in pixels as WIDTHxHEIGHT, e.g. 2560x1600. Omit to use the default."))) var size: String?

    struct Result: Encodable, Sendable { let width: Int; let height: Int }

    func validate() throws {
        if let size, Self.parse(size) == nil { throw ValidationError(String(l10n: "Size must be WIDTHxHEIGHT, e.g. 2560x1600")) }
    }

    static func parse(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in "\(r.width)x\(r.height)" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let display = try bundle.loadConfig().display
            let (width, height) = size.flatMap(Self.parse) ?? (display.width, display.height)
            try ControlClient.perform(.display(width: width, height: height), on: bundle)
            return Result(width: width, height: height)
        }
    }
}
