import ArgumentParser
import Foundation
import MacVMModel

@main
struct MacVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macvm",
        abstract: String(l10n: "Run macOS, Linux, and Windows virtual machines on Apple Silicon."),
        discussion: discussion,
        version: appVersion,
        subcommands: [
            Create.self, Set.self, List.self, Run.self, Start.self, Stop.self, Suspend.self,
            Status.self, IP.self, Wait.self, Screenshot.self, Display.self, CloneCommand.self, SnapshotCommand.self, TemplateCommand.self,
            Exec.self, Copy.self, SSH.self, Proxy.self, SSHConfigCommand.self, Agent.self, Update.self, UICommand.self, Tune.self,
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
    return String(l10n: """
    Every command accepts --json and then prints a single line to standard output: {"schemaVersion":1,"result":…} on success, or {"schemaVersion":1,"error":{"code":…,"message":…}} on failure.

    Exit codes:
      0   Success
      1   Other error
    \(rows.joined(separator: "\n"))
      64  Command-line usage error

    You can change the VM, downloads, and templates folders in the app's settings. The CLI reads the same file (~/Library/Application Support/MacVM/settings.json).
    MACVM_HOME, if set, overrides the VM folder from settings.
    """)
}()

struct GlobalOptions: ParsableArguments {
    @Flag(help: ArgumentHelp(String(l10n: "Output the result as JSON.")))
    var json = false
}
