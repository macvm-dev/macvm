public import ArgumentParser
import Foundation
public import MacVMEngine
import MacVMModel

extension MacOSTuning.Step: ExpressibleByArgument {}

struct Tune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Tune a macOS guest to reduce idle CPU, disk, and memory usage."),
        discussion: String(l10n: """
        Changes system settings in the guest over SSH, starting the VM if it isn't running. Steps:
          spotlight     Turn off Spotlight indexing (Finder and Spotlight can no longer search file contents)
          sleep         Turn off system sleep, disk sleep, and Power Nap (the display still sleeps)
          screensaver   Turn off the screen saver
          updates       Turn off automatic checking, downloading, and installing of system updates
          animations    Turn off window and Dock animations
          transparency  Turn on Reduce Transparency and Reduce Motion; if SSH doesn't have Full Disk Access, this fails
                        and you need to turn them on in the guest under System Settings > Accessibility > Display
        spotlight, sleep, and updates need sudo, which uses the guest password saved in the VM bundle (every VM created with macvm create --os macos has one).
        --revert restores the selected steps to system defaults.
        """)
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Option(help: ArgumentHelp(String(l10n: "Skip a step (repeatable)."))) var skip: [MacOSTuning.Step] = []
    @Flag(help: ArgumentHelp(String(l10n: "Restore the selected steps to system defaults."))) var revert = false
    @Option(help: ArgumentHelp(String(l10n: "Guest password (default: guest-password in the VM bundle)."))) var password: String?

    func run() async throws {
        try await Output.run(json: global.json, human: { Self.render(name, $0) }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let config = try bundle.loadConfig()
            guard config.os == .macOS else { throw MacVMError.unsupported(String(l10n: "Only macOS guests can be tuned")) }
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
            lines.append(r.reverted
                ? String(l10n: "Reverted \(name) to defaults: \(r.applied.map(\.rawValue).joinedAsList())")
                : String(l10n: "Tuned \(name): \(r.applied.map(\.rawValue).joinedAsList())"))
        }
        if !r.failed.isEmpty {
            lines.append(String(l10n: "Couldn't apply: \(r.failed.map(\.rawValue).joinedAsList())"))
            if r.failed.contains(.transparency), !r.reverted {
                lines.append(String(l10n: "To finish transparency, turn on Reduce Transparency and Reduce Motion yourself in the guest under System Settings > Accessibility > Display"))
            }
        }
        return lines.isEmpty ? String(l10n: "Nothing to do") : lines.joined(separator: "\n")
    }
}
