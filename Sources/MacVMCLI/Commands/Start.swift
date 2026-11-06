import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "在后台启动虚拟机，启动完成后返回。",
        discussion: "后台进程的日志写在虚拟机包内的 run.log。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Option(help: "等待启动完成的最长秒数。")
    var timeout: Int = 60

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "\(s.name) 已在后台运行（pid \(s.pid.map(String.init) ?? "?")）" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(name) }
            return try await Self.launch(bundle, timeout: timeout)
        }
    }

    /// 用本 CLI 派生后台进程。
    static func launch(_ bundle: VMBundle, timeout: Int) async throws -> VMSummary {
        try bundle.requireNotCreating()
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return try await DetachedRun.launch(bundle, executable: executable, timeout: timeout)
    }
}
