import ArgumentParser
import Foundation
import MacVMModel

@main
struct MacVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macvm",
        abstract: "在 Apple Silicon 上运行 macOS、Linux、Windows 虚拟机。",
        discussion: discussion,
        version: appVersion,
        subcommands: [
            Create.self, Set.self, List.self, Run.self, Start.self, Stop.self, Suspend.self,
            Status.self, IP.self, Wait.self, Screenshot.self, Display.self, CloneCommand.self, SnapshotCommand.self, TemplateCommand.self,
            Exec.self, SSH.self, Proxy.self, SSHConfigCommand.self, Agent.self, Update.self, UICommand.self, Tune.self,
            Delete.self, Doctor.self,
        ]
    )
}

/// 版本号只写在 App 包的属性列表里；CLI 放在包内的固定层级，从包的属性列表读取。不在 App 包里运行时为 `dev`。
private let appVersion: String = {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
    let plist = exe.deletingLastPathComponent().appending(path: "../../Info.plist").standardizedFileURL
    return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
}()

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

    虚拟机目录、下载目录与模板目录可在 App 设置里更改（存在 ~/Library/Application Support/MacVM/settings.json，CLI 同样遵循）；
    环境变量 MACVM_HOME 优先于设置里的虚拟机目录。
    """
}()

struct GlobalOptions: ParsableArguments {
    @Flag(help: "以 JSON 输出结果。")
    var json = false
}
