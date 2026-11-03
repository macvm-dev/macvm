import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "把运行中虚拟机的画面存为 PNG（QEMU 引擎）。")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Argument(help: "输出文件。") var output: String

    struct Result: Encodable, Sendable { let path: String }

    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in r.path }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let url = URL(filePath: (output as NSString).expandingTildeInPath).standardizedFileURL
            _ = try ControlClient.check(ControlClient.send(.screenshot(path: url.path), to: bundle), bundle: bundle)
            return Result(path: url.path)
        }
    }
}
