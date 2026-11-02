import ArgumentParser
import Foundation
import MacVMModel

@main
struct MacVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macvm",
        abstract: "在 Apple Silicon 上运行 macOS、Linux、Windows 虚拟机。",
        discussion: discussion,
        version: "0.1.0",
        subcommands: [
            Create.self, InstallMacOS.self, List.self, Run.self, Start.self, Stop.self, Suspend.self,
            Status.self, IP.self, Wait.self, CloneCommand.self, SnapshotCommand.self,
            Exec.self, SSH.self, Proxy.self, SSHConfigCommand.self, Agent.self,
            Delete.self, Doctor.self,
        ]
    )
}

private let discussion: String = {
    let rows = MacVMError.catalog.map { e in
        "  \(String(e.exitCode).padding(toLength: 4, withPad: " ", startingAt: 0))\(e.code.padding(toLength: 20, withPad: " ", startingAt: 0))\(e.summary)"
    }
    return """
    所有命令都支持 --json：标准输出是一行 {"schemaVersion":1,"result":…}，失败时是 {"schemaVersion":1,"error":{"code":…,"message":…}}。

    退出码：
      0   成功
      1   其他错误
    \(rows.joined(separator: "\n"))
      64  命令行用法错误

    环境变量 MACVM_HOME 可改变虚拟机存放目录。
    """
}()

struct GlobalOptions: ParsableArguments {
    @Flag(help: "以 JSON 输出结果。")
    var json = false
}
