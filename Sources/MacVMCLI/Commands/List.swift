import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "列出虚拟机。")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Output.run(json: global.json, human: Self.table) {
            try VMLibrary.default.all().compactMap { try? VMStatus.summary(of: $0) }
        }
    }

    static func table(_ rows: [VMSummary]) -> String {
        guard !rows.isEmpty else { return "还没有虚拟机，用 macvm create 创建。" }
        let header = ["NAME", "OS", "STATE", "CPU", "MEMORY", "IP"]
        let body = rows.map { [$0.name, $0.os.rawValue, $0.state.rawValue, "\($0.cpuCount)", ByteSize.format($0.memorySize), $0.ipAddress ?? "-"] }
        let widths = header.indices.map { i in ([header] + body).map { $0[i].count }.max() ?? 0 }
        return ([header] + body).map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0] + 2, withPad: " ", startingAt: 0) }.joined()
        }.joined(separator: "\n")
    }
}
