public import ArgumentParser
import Foundation
public import MacVMEngine
import MacVMModel

extension MacOSTuning.Step: ExpressibleByArgument {}

struct Tune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "调优 macOS 客户机，降低空闲时的 CPU、磁盘与内存占用。",
        discussion: """
        经 SSH 修改客户机里的系统设置，未运行时自动启动。各项：
          spotlight     关闭 Spotlight 索引（访达与聚焦搜索不再能按内容查找）
          sleep         关闭系统睡眠、磁盘睡眠与 Power Nap（显示器照常睡眠）
          screensaver   关闭屏幕保护程序
          updates       关闭自动检查、下载与安装系统更新
          animations    关闭窗口与 Dock 动画
          transparency  打开减少透明度与减少动态效果；SSH 没有完全磁盘访问权限时会失败，
                        可在客户机的 系统设置 > 辅助功能 > 显示 里手动打开
        spotlight、sleep、updates 要 sudo，用包内保存的客户机密码（install-macos 创建的虚拟机都有）。
        --revert 把所选各项恢复为系统默认。
        """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String
    @Option(help: "跳过某项，可重复。") var skip: [MacOSTuning.Step] = []
    @Flag(help: "把所选各项恢复为系统默认。") var revert = false
    @Option(help: "客户机密码，默认读包内的 guest-password。") var password: String?

    func run() async throws {
        try await Output.run(json: global.json, human: { Self.render(name, $0) }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let config = try bundle.loadConfig()
            guard config.os == .macOS else { throw MacVMError.unsupported("只有 macOS 客户机可以调优") }
            var probe = config
            probe.guestAgent = false
            try await Wait.untilReady(bundle, config: probe, timeout: 300)
            // App 创建的虚拟机没装过 macvm 密钥；有密码就先装上，已装过时什么也不改。
            if let user = config.guestUser, let pw = password ?? GuestCredentials.password(for: bundle) {
                let proxy = SSHConfig.proxyCommand(macvmPath: SSHConfigCommand.executablePath, name: name, flags: ["--tcp"])
                try await GuestSSH.installPublicKey(bundle: bundle, user: user, password: pw, proxyCommand: proxy, timeout: 60)
            }
            let steps = MacOSTuning.Step.allCases.filter { !skip.contains($0) }
            return try await MacOSTuning.run(bundle: bundle, config: config, steps: steps, revert: revert,
                                             password: password, macvmPath: SSHConfigCommand.executablePath)
        }
    }

    static func render(_ name: String, _ r: MacOSTuning.Report) -> String {
        var lines: [String] = []
        if !r.applied.isEmpty {
            lines.append("\(r.reverted ? "已恢复默认" : "已调优") \(name)：\(r.applied.map(\.rawValue).joined(separator: "、"))")
        }
        if !r.failed.isEmpty {
            lines.append("未生效：\(r.failed.map(\.rawValue).joined(separator: "、"))")
            if r.failed.contains(.transparency), !r.reverted {
                lines.append("transparency 需在客户机的 系统设置 > 辅助功能 > 显示 里手动打开减少透明度与减少动态效果")
            }
        }
        return lines.isEmpty ? "没有要执行的项" : lines.joined(separator: "\n")
    }
}
