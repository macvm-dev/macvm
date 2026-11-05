import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Display: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "调整运行中虚拟机的显示尺寸（VZ 引擎与自带的 QEMU）。",
        discussion: "只改本次运行；省略尺寸时恢复为默认尺寸，默认尺寸用 set --display 修改。VZ 下 Windows 的分辨率固定，不支持调整。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Argument(help: "宽x高，单位像素，如 2560x1600；省略时用默认尺寸。") var size: String?

    struct Result: Encodable, Sendable { let width: Int; let height: Int }

    func validate() throws {
        if let size, Self.parse(size) == nil { throw ValidationError("尺寸格式应为 宽x高，如 2560x1600") }
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
