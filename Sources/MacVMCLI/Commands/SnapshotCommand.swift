import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "管理快照（虚拟机须已停止或挂起）。",
        discussion: "快照是 APFS clonefile 副本，只为之后改动的块占用空间。挂起中做的快照包含内存，还原后 start 直接接着运行。",
        subcommands: [Save.self, Restore.self, List.self, Remove.self]
    )

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "创建快照。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var vm: String
        @Argument(help: "快照名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (s: Snapshot) in "已创建快照 \(s.name)\(s.includesMemory ? "（含内存）" : "")" }) {
                try Snapshot.save(VMLibrary.default.bundle(named: vm), name: name)
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "还原快照，当前未快照的改动会丢失。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var vm: String
        @Argument(help: "快照名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in "已还原到 \(name)" }) {
                try Snapshot.restore(VMLibrary.default.bundle(named: vm), name: name)
                return Empty()
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "列出快照。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var vm: String

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try Snapshot.list(VMLibrary.default.bundle(named: vm))
            }
        }

        static func render(_ snaps: [Snapshot]) -> String {
            guard !snaps.isEmpty else { return "没有快照" }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return snaps.map { "\($0.name)\t\(f.string(from: $0.createdAt))\t\($0.includesMemory ? "含内存" : "磁盘")" }.joined(separator: "\n")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "删除快照。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var vm: String
        @Argument(help: "快照名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in "已删除快照 \(name)" }) {
                try Snapshot.delete(VMLibrary.default.bundle(named: vm), name: name)
                return Empty()
            }
        }
    }
}
