import Foundation
public import MacVMModel

public enum VMClone {
    /// 源虚拟机须已停止。挂起状态不复制：它绑定源机器的标识与网卡，换了标识后无法恢复。
    /// `customize` 在新包的文件都就位、配置保存前调用；它抛错时新包整个删掉。
    public static func clone(_ source: VMBundle, as name: String, in library: VMLibrary = .default, creationToken: String? = nil,
                             customize: (inout VMConfig, VMBundle) throws -> Void = { _, _ in }) async throws -> VMBundle {
        if BundleLock.holder(of: source) != nil { throw MacVMError.alreadyRunning(source.name) }
        var config = try source.loadConfig()
        return try await VMFactory.withNewBundle(named: name, in: library, creationToken: creationToken) { target in
            for file in BundleFiles.stateFiles(of: source, config: config) {
                try Clone.file(from: source.url.appending(path: file), to: target.url.appending(path: file))
            }
            // 磁盘是复制来的，客户机密码与代理令牌与源机相同。
            let password = GuestCredentials.password(for: source)
            if let password { try GuestCredentials.storePassword(password, in: target) }
            if let token = AgentToken.read(source) { try AgentToken.store(token, in: target) }
            try MachineIdentity.regenerate(in: target, os: config.os)
            config.name = name
            for i in config.networks.indices { config.networks[i].macAddress = NetworkAttachments.randomMACAddress() }
            // 宿主端口同一时刻只能一台监听，不随克隆带走。
            config.forwards = []

            // 新 instance-id 让 cloud-init 当作新机器重跑：改主机名、重新生成主机密钥、按新 MAC 配网。
            if config.disks.contains(where: { $0.path == CloudInit.seedFileName }), let user = config.guestUser {
                // 代理已装在磁盘上，种子盘不再携带；时区沿用源机磁盘上的设置。
                // 换了 instance-id，cloud-init 会按种子盘重新设置用户，密码要与源机一致。
                let seed = CloudInit.Options(hostname: name, user: user, password: password, sshPublicKey: try await SSHKeys.ensurePublicKey(),
                                             macAddress: config.networks.first?.macAddress ?? "", shares: config.shares, rosetta: config.rosetta,
                                             timezone: nil, agentBinary: nil)
                try await CloudInit.writeSeed(seed, instanceID: UUID().uuidString, in: target)
            }
            try customize(&config, target)
            try target.saveConfig(config)
            return target
        }
    }
}
