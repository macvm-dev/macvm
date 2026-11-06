import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: String(l10n: "Manage templates for creating VMs."),
        discussion: String(l10n: "Save a shut-down VM as a template, then create VMs from it with macvm create <name> --template <template>. Templates are stored in the templates folder, which you can change in the app's settings. On the same APFS volume nothing is actually copied. VMs created from a template get a new machine identifier and MAC address, and those from cloud images are re-initialized with a new hostname."),
        subcommands: [Save.self, List.self, Remove.self]
    )

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Save a shut-down VM as a template, without its snapshots."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var vm: String
        @Argument(help: ArgumentHelp(String(l10n: "Template name (default: the VM name)."))) var name: String?

        func run() async throws {
            try await Output.run(json: global.json, human: { (t: TemplateSummary) in String(l10n: "Saved template \(t.name): \(t.path)") }) {
                let template = try await VMTemplate.save(VMLibrary.default.bundle(named: vm), as: name ?? vm)
                return try VMTemplate.summary(of: template)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: String(l10n: "List templates."))
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await Output.run(json: global.json, human: Self.table) { VMTemplate.summaries() }
        }

        static func table(_ rows: [TemplateSummary]) -> String {
            guard !rows.isEmpty else { return String(l10n: "No templates yet. Create one with macvm template save.") }
            let header = ["NAME", "OS", "ENGINE", "CPU", "MEMORY", "DISK"]
            let body = rows.map {
                [$0.name, $0.os.rawValue, $0.engine.rawValue, "\($0.cpuCount)", ByteSize.format($0.memorySize), $0.diskSize.map(ByteSize.format) ?? "-"]
            }
            return textTable(header: header, rows: body)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: String(l10n: "Delete a template. VMs created from it aren't affected."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "Template name."))) var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "Deleted template \(name)") }) {
                try VMTemplate.delete(named: name)
                return Empty()
            }
        }
    }
}
