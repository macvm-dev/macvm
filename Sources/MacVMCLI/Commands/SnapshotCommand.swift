import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: String(l10n: "Manage snapshots (the VM must be stopped or suspended)."),
        discussion: String(l10n: "Snapshots are APFS clones, so they only use space for data that changes afterward. A snapshot of a suspended VM includes its memory: after you restore it, the next start resumes right where it left off."),
        subcommands: [Save.self, Restore.self, List.self, Remove.self]
    )

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Create a snapshot."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var vm: String
        @Argument(help: ArgumentHelp(String(l10n: "Snapshot name."))) var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (s: Snapshot) in s.includesMemory ? String(l10n: "Created snapshot \(s.name) (with memory)") : String(l10n: "Created snapshot \(s.name)") }) {
                try Snapshot.save(VMLibrary.default.bundle(named: vm), name: name)
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Restore a snapshot. Any changes not saved in a snapshot are lost."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var vm: String
        @Argument(help: ArgumentHelp(String(l10n: "Snapshot name."))) var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "Restored snapshot \(name)") }) {
                try Snapshot.restore(VMLibrary.default.bundle(named: vm), name: name)
                return Empty()
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: String(l10n: "List snapshots."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var vm: String

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try Snapshot.list(VMLibrary.default.bundle(named: vm))
            }
        }

        static func render(_ snaps: [Snapshot]) -> String {
            guard !snaps.isEmpty else { return String(l10n: "No snapshots") }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return snaps.map { "\($0.name)\t\(f.string(from: $0.createdAt))\t\($0.includesMemory ? String(l10n: "with memory") : String(l10n: "disk only"))" }.joined(separator: "\n")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: String(l10n: "Delete a snapshot."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var vm: String
        @Argument(help: ArgumentHelp(String(l10n: "Snapshot name."))) var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in String(l10n: "Deleted snapshot \(name)") }) {
                try Snapshot.delete(VMLibrary.default.bundle(named: vm), name: name)
                return Empty()
            }
        }
    }
}
