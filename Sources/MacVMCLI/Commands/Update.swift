import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Bring a running VM's guest agent and guest settings up to date with this version of the app."),
        discussion: String(l10n: """
        Works through the guest agent; SSH isn't needed. The agent is replaced first (it restarts once), then any setup the installer has gained since the VM was created is applied, such as Windows virtio drivers.
        Some settings take effect only after the guest restarts; add --reboot to restart it right away. Updating the Windows 3D graphics driver always restarts the guest. Use --check to list pending updates without applying them.
        """)
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
    @Flag(help: ArgumentHelp(String(l10n: "List pending updates without applying them."))) var check = false
    @Flag(help: ArgumentHelp(String(l10n: "Restart the guest right away if an update needs it."))) var reboot = false

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
        guard !p.isEmpty else { return String(l10n: "\(name) is up to date") }
        return ([String(l10n: "Updates available for \(name):")] + (p.agent ? ["- " + String(l10n: "Guest agent")] : []) + p.changes.map { "- \($0)" }).joined(separator: "\n")
    }

    static func render(_ name: String, _ r: GuestUpdate.Result, rebooted: Bool) -> String {
        guard r.agentUpdated || !r.applied.isEmpty else { return String(l10n: "\(name) is up to date") }
        var lines = [String(l10n: "Updated \(name):")] + (r.agentUpdated ? ["- " + String(l10n: "Guest agent")] : []) + r.applied.map { "- \($0)" }
        if r.rebooting { lines.append(String(l10n: "The 3D graphics driver was also updated; restarting the guest")) }
        if r.rebootRequired { lines.append(rebooted ? String(l10n: "Restarting the guest so that some settings can take effect") : String(l10n: "Some settings take effect after you restart the guest")) }
        return lines.joined(separator: "\n")
    }
}
