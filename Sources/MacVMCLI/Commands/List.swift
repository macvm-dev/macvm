import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "列出虚拟机。")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Output.run(json: global.json, human: Self.table) {
            VMStatus.summaries(in: VMLibrary.default)
        }
    }

    static func table(_ rows: [VMSummary]) -> String {
        guard !rows.isEmpty else { return "还没有虚拟机，用 macvm create 创建。" }
        let header = ["NAME", "OS", "STATE", "CPU", "MEMORY", "IP"]
        let body = rows.map { [$0.name, $0.os.rawValue, $0.state.rawValue, "\($0.cpuCount)", ByteSize.format($0.memorySize), $0.ipAddress ?? "-"] }
        return textTable(header: header, rows: body)
    }
}

/// 按列左对齐的纯文本表格，列宽取该列最长的单元格再空两格。
func textTable(header: [String], rows: [[String]]) -> String {
    let all = [header] + rows
    let widths = header.indices.map { i in all.map { $0[i].count }.max() ?? 0 }
    return all.map { row in
        row.enumerated().map { $1.padding(toLength: widths[$0] + 2, withPad: " ", startingAt: 0) }.joined()
    }.joined(separator: "\n")
}
