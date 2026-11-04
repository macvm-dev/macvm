import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "管理模板：把已关机的虚拟机存为模板，再用 macvm create <名> --template <模板> 从它新建。",
        discussion: "模板存在模板目录（App 设置里可改）。APFS 同卷时零拷贝；由模板新建的虚拟机获得新的机器标识与 MAC，云镜像虚拟机会以新主机名重新初始化。",
        subcommands: [Save.self, List.self, Remove.self]
    )

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "把已关机的虚拟机存为模板（不含快照）。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var vm: String
        @Argument(help: "模板名称，缺省与虚拟机同名。") var name: String?

        func run() async throws {
            try await Output.run(json: global.json, human: { (t: TemplateSummary) in "已存为模板 \(t.name)：\(t.path)" }) {
                let template = try await VMTemplate.save(VMLibrary.default.bundle(named: vm), as: name ?? vm)
                return try VMTemplate.summary(of: template)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "列出模板。")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await Output.run(json: global.json, human: Self.table) { VMTemplate.summaries() }
        }

        static func table(_ rows: [TemplateSummary]) -> String {
            guard !rows.isEmpty else { return "还没有模板，用 macvm template save 创建。" }
            let header = ["NAME", "OS", "ENGINE", "CPU", "MEMORY", "DISK"]
            let body = rows.map {
                [$0.name, $0.os.rawValue, $0.engine.rawValue, "\($0.cpuCount)", ByteSize.format($0.memorySize), $0.diskSize.map(ByteSize.format) ?? "-"]
            }
            return textTable(header: header, rows: body)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "删除模板。由它新建的虚拟机不受影响。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "模板名称。") var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in "已删除模板 \(name)" }) {
                try VMTemplate.delete(named: name)
                return Empty()
            }
        }
    }
}
