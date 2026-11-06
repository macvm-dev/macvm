import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Manage the guest agent (macvm-agent)."),
        discussion: String(l10n: "The agent handles exec, port forwarding, shutdown, time sync, the clipboard, and UI automation (macvm ui). Linux and macOS guests on VZ reach it over vsock, which works without guest networking; Windows and Linux guests on QEMU use TCP. It's installed automatically in macOS VMs, VMs created from cloud images, automatically installed Ubuntu Desktop, and Windows VMs set up by the installer."),
        subcommands: [Install.self, Info.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: String(l10n: "Install or update the agent."),
            discussion: String(l10n: "If the agent is online, it replaces itself with the version bundled with the app; SSH isn't needed. Otherwise it's installed over SSH, which is also used when an auth token needs to be written, when the Windows 3D graphics driver needs to be copied into the guest, or when you pass --ssh.")
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Flag(help: ArgumentHelp(String(l10n: "Install over SSH even if the agent is online."))) var ssh = false

        func run() async throws {
            var gpuDriver = false
            var updated: AgentUpdate.Result?
            try await Output.run(json: global.json, human: { (_: InfoResult) in
                if let updated {
                    guard updated.changed else { return String(l10n: "The guest agent on \(name) already matches the app's version; add --ssh to reinstall") }
                    return updated.rebooting
                        ? String(l10n: "Updated the guest agent and 3D graphics driver on \(name); restarting the guest")
                        : String(l10n: "Updated the guest agent on \(name)")
                }
                return gpuDriver
                    ? String(l10n: "Installed the guest agent and 3D graphics driver on \(name); the desktop will use GPU compositing after the guest restarts")
                    : String(l10n: "Installed the guest agent on \(name)")
            }) {
                let bundle = try VMLibrary.default.bundle(named: name)
                let config = try bundle.loadConfig()
                if !ssh, config.guestAgent, AgentUpdate.coversInstall(bundle, config: config), AgentClient.isReachable(bundle) {
                    updated = try await AgentUpdate.update(bundle)
                    return try InfoResult(bundle)
                }
                var probe = config
                probe.guestAgent = false
                try await Wait.untilReady(bundle, config: probe, timeout: 300)
                let result = try await AgentInstaller.installAndEnable(bundle: bundle, config: config, macvmPath: SSHConfigCommand.executablePath)
                gpuDriver = result.gpuDriver
                guard result.online else { throw MacVMError.timeout(String(l10n: "Installed the agent, but it isn't responding")) }
                return try InfoResult(bundle)
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Show guest information reported by the agent."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try InfoResult(VMLibrary.default.bundle(named: name))
            }
        }

        static func render(_ r: InfoResult) -> String {
            render(r.info) + (r.updateAvailable == true ? "\n" + String(l10n: "The app bundles a different agent version; run macvm agent install \(r.name) to update") : "")
        }

        static func render(_ i: AgentProtocol.Info) -> String {
            String(l10n: """
            Agent \(i.version) · \(i.os) · \(i.hostname)
            IPv4: \(i.ipv4.joinedAsList())
            Memory: \(ByteSize.format(i.memAvailable)) of \(ByteSize.format(i.memTotal)) available
            Uptime: \(i.uptimeMs / 1000) s
            """)
        }
    }

    /// 代理报告的信息，外加它是否与随 App 分发的代理不同；无从比对时省略 `updateAvailable`。
    struct InfoResult: Encodable {
        let name: String
        let info: AgentProtocol.Info
        let updateAvailable: Bool?

        init(_ bundle: VMBundle) throws {
            name = bundle.name
            info = try AgentClient.info(bundle)
            updateAvailable = switch AgentUpdate.status(of: info, os: try bundle.loadConfig().os) {
            case .current: false
            case .outdated: true
            case .unknown: nil
            }
        }

        private enum Keys: String, CodingKey { case updateAvailable }

        func encode(to encoder: any Encoder) throws {
            try info.encode(to: encoder)
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(updateAvailable, forKey: .updateAvailable)
        }
    }
}
