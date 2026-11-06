import Foundation
public import MacVMModel

/// 把运行中的虚拟机里随 App 分发、或由安装流程做好的东西更新到 App 当前的版本：
/// 客户机代理（`AgentUpdate`），以及还没做的 `GuestMigration`。全程经代理，不需要 SSH。
public enum GuestUpdate {
    public struct Pending: Sendable, Equatable, Encodable {
        /// 客户机里的代理与随 App 分发的不同。
        public let agent: Bool
        /// 要补做的客户机设置，每项一句话。
        public let changes: [String]

        public var isEmpty: Bool { !agent && changes.isEmpty }
    }

    public struct Result: Sendable, Encodable {
        public let agentUpdated: Bool
        public let applied: [String]
        /// 换了 Windows 的 3D 显卡驱动，已请客户机重启。
        public let rebooting: Bool
        /// 有的设置要重启客户机才生效，客户机还没重启。
        public let rebootRequired: Bool
    }

    /// 运行中的 `bundle` 待做的更新。经代理查询，没装代理或代理没上线时抛错；阻塞的 socket 往返，不要在应答控制 socket 的 actor 上调用。
    public static func pending(_ bundle: VMBundle) throws -> Pending {
        let config = try bundle.loadConfig()
        guard config.guestAgent else { throw noAgent(config) }
        let info = try AgentClient.info(bundle)
        return Pending(agent: AgentUpdate.status(of: info, os: config.os) == .outdated,
                       changes: GuestMigration.pending(for: config).map(\.title))
    }

    /// 先换代理，再按修订号逐条补做设置，每做完一条就记进 `VMConfig.guestRevision`；中途失败时已做完的不再重做。
    /// 换了代理的 Windows 最后经新代理补推 3D 显卡驱动。`progress` 在任意线程上收到当前步骤。
    public static func apply(_ bundle: VMBundle, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        try await Task.detached { try await perform(bundle, progress: progress) }.value
    }

    private static func perform(_ bundle: VMBundle, progress: @Sendable (String) -> Void) async throws -> Result {
        let config = try bundle.loadConfig()
        guard config.guestAgent else { throw noAgent(config) }
        var agentUpdated = false
        if AgentUpdate.status(of: try AgentClient.info(bundle), os: config.os) == .outdated {
            progress(String(l10n: "Updating the guest agent…"))
            agentUpdated = try await AgentUpdate.replace(bundle)
        }
        let migrations = GuestMigration.pending(for: config)
        var applied: [String] = []
        var rebootRequired = false
        for (index, migration) in migrations.enumerated() {
            progress(String(l10n: "Updating guest settings (\(index + 1)/\(migrations.count)): \(migration.title)…"))
            let (request, input) = try await migration.prepare(config)
            let (code, output) = try AgentClient.run(bundle, request: request, input: input, timeout: migrationTimeout)
            guard code == 0 else {
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let status = code.map { String(l10n: "exit code \($0)") } ?? String(l10n: "the guest agent disconnected")
                throw MacVMError.engine(String(l10n: "Couldn't update guest setting “\(migration.title)” (\(status))") + (detail.isEmpty ? "" : String(l10n: ": \(detail)")))
            }
            if output.contains(GuestMigration.rebootMarker) { rebootRequired = true }
            var latest = try bundle.loadConfig()
            latest.guestRevision = migration.revision
            try bundle.saveConfig(latest)
            applied.append(migration.title)
        }
        let rebooting = agentUpdated ? try AgentUpdate.syncGPUDriver(bundle, config: config) : false
        return Result(agentUpdated: agentUpdated, applied: applied, rebooting: rebooting, rebootRequired: rebootRequired && !rebooting)
    }

    private static func noAgent(_ config: VMConfig) -> MacVMError {
        .unsupported(String(l10n: "The guest agent isn't installed in \(config.name); run macvm agent install \(config.name) first"))
    }

    /// 单条设置的读超时：装驱动时 pnputil 可能几分钟没有输出。
    private static let migrationTimeout = 600

    /// 请客户机重启，`Result.rebootRequired` 之后用。
    public static func reboot(_ bundle: VMBundle) throws {
        _ = try AgentClient.call(.shutdown(reboot: true), bundle: bundle, timeout: 5)
    }
}
