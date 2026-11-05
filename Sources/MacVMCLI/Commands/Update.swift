import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把运行中的虚拟机里的代理与客户机设置更新到 App 当前的版本。",
        discussion: """
        经客户机代理完成，不需要 SSH：先换代理（代理重启一次），再补做建机之后安装流程新增的设置（如 Windows 的 virtio 驱动）。
        有的设置要重启客户机生效，加 --reboot 时随即重启；换了 Windows 的 3D 显卡驱动时总会重启。--check 只列出待做的更新。
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Flag(help: "只列出待做的更新，不执行。") var check = false
    @Flag(help: "设置要重启才生效时随即重启客户机。") var reboot = false

    func run() async throws {
        let bundle = try VMLibrary.default.bundle(named: name)
        if check {
            try await Output.run(json: global.json, human: { (p: GuestUpdate.Pending) in Self.render(name, p) }) {
                try GuestUpdate.pending(bundle)
            }
            return
        }
        let interactive = !global.json && isatty(STDERR_FILENO) == 1
        try await Output.run(json: global.json, human: { (r: GuestUpdate.Result) in Self.render(name, r, rebooted: reboot) }) {
            let result = try await GuestUpdate.apply(bundle) { step in
                if interactive { FileHandle.standardError.write(Data((step + "\n").utf8)) }
            }
            if reboot, result.rebootRequired { try GuestUpdate.reboot(bundle) }
            return result
        }
    }

    static func render(_ name: String, _ p: GuestUpdate.Pending) -> String {
        guard !p.isEmpty else { return "\(name) 已是最新" }
        return (["\(name) 有可用更新："] + (p.agent ? ["- 客户机代理"] : []) + p.changes.map { "- \($0)" }).joined(separator: "\n")
    }

    static func render(_ name: String, _ r: GuestUpdate.Result, rebooted: Bool) -> String {
        guard r.agentUpdated || !r.applied.isEmpty else { return "\(name) 已是最新" }
        var lines = ["已更新 \(name)："] + (r.agentUpdated ? ["- 客户机代理"] : []) + r.applied.map { "- \($0)" }
        if r.rebooting { lines.append("3D 显卡驱动也已更新，正在重启客户机") }
        if r.rebootRequired { lines.append(rebooted ? "正在重启客户机，部分设置重启后生效" : "部分设置要重启客户机后生效") }
        return lines.joined(separator: "\n")
    }
}
