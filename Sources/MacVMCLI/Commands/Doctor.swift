import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: String(l10n: "Check which features this Mac supports and this build of macvm is signed for."))

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Output.run(json: global.json, human: Self.render) { HostCapabilities.current() }
    }

    static func render(_ c: HostCapabilities) -> String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        let qemu = c.qemu.map { String(l10n: "✓ QEMU engine: \($0)") }
            ?? String(l10n: "✗ QEMU engine (needed to install Windows; brew install qemu)")
        return [
            String(l10n: "macOS \(c.hostOS), \(c.performanceCores) performance cores, \(ByteSize.format(c.physicalMemory)) of memory"),
            String(l10n: "\(mark(c.virtualization)) Virtualization (Apple Silicon + com.apple.security.virtualization)"),
            String(l10n: "\(mark(c.windows)) Windows guests on VZ (Virtualization.framework PMU emulation)"),
            qemu,
            "\(mark(c.rosetta)) Linux Rosetta\(c.rosetta ? "" : " (softwareupdate --install-rosetta)")",
            String(l10n: "\(mark(c.saveRestore)) Suspend and resume"),
            String(l10n: "VM folder: \(c.libraryPath)"),
            String(l10n: "Downloads folder: \(c.downloadPath)"),
            String(l10n: "Templates folder: \(c.templatePath)"),
        ].joined(separator: "\n")
    }
}
