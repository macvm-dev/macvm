public import Foundation
public import MacVMModel

public enum VMClone {
    /// 源虚拟机须已停止。挂起状态不复制：它绑定源机器的标识与网卡，换了标识后无法恢复。
    public static func clone(_ source: VMBundle, as name: String, in library: VMLibrary = .default) async throws -> VMBundle {
        if BundleLock.holder(of: source) != nil { throw MacVMError.alreadyRunning(source.name) }
        var config = try source.loadConfig()
        let target = try VMFactory.prepareEmptyBundle(named: name, in: library)
        do {
            for file in BundleFiles.stateFiles(of: source, config: config) {
                try Clone.file(from: source.url.appending(path: file), to: target.url.appending(path: file))
            }
            try MachineIdentity.regenerate(in: target, os: config.os)
            config.name = name
            for i in config.networks.indices { config.networks[i].macAddress = NetworkAttachments.randomMACAddress() }

            // 新 instance-id 让 cloud-init 当作新机器重跑：改主机名、重新生成主机密钥、按新 MAC 配网。
            if config.disks.contains(where: { $0.path == CloudInit.seedFileName }), let user = config.guestUser {
                // 代理已装在磁盘上，种子盘不再携带。
                let seed = CloudInit.Options(hostname: name, user: user, sshPublicKey: try await SSHKeys.ensurePublicKey(),
                                             macAddress: config.networks.first?.macAddress ?? "", shares: config.shares, rosetta: config.rosetta,
                                             agentBinary: nil)
                try await CloudInit.writeSeed(seed, instanceID: UUID().uuidString, in: target)
            }
            try target.saveConfig(config)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target.url)
            throw error
        }
    }
}
