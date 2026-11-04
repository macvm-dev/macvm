public import Foundation
public import MacVMModel

/// 生成 NoCloud 种子盘（卷标 `cidata` 的 ISO），首启时由客户机的 cloud-init 读取。
public enum CloudInit {
    public static let seedFileName = "cidata.iso"

    /// 种子盘一直挂着，cloud-init 每次开机都执行 `userData` 里的 growpart，系统盘扩容后根分区随之扩展。
    public static func growsRootPartition(_ config: VMConfig) -> Bool {
        config.disks.contains { $0.path == seedFileName }
    }

    public struct Options: Sendable {
        public var hostname: String
        public var user: String
        /// 控制台登录密码；nil 时锁定密码登录。SSH 始终只认密钥。
        public var password: String?
        public var sshPublicKey: String
        public var shares: [ShareConfig]
        public var rosetta: Bool
        public var macAddress: String
        /// 放进种子盘并在首启时安装为 systemd 服务的代理二进制。
        public var agentBinary: URL?

        public init(hostname: String, user: String, password: String? = nil, sshPublicKey: String, macAddress: String, shares: [ShareConfig] = [],
                    rosetta: Bool = false, agentBinary: URL? = AgentInstaller.binary(for: .linux)) {
            self.hostname = hostname
            self.user = user
            self.password = password
            self.sshPublicKey = sshPublicKey
            self.shares = shares
            self.rosetta = rosetta
            self.macAddress = macAddress
            self.agentBinary = agentBinary
        }
    }

    /// `instanceID` 变化时 cloud-init 视为新实例重新执行；克隆后应传入新的值。
    public static func writeSeed(_ options: Options, instanceID: String, in bundle: VMBundle) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "macvm-cidata-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try metaData(instanceID: instanceID, hostname: options.hostname).write(to: staging.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData(options).write(to: staging.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try networkConfig(macAddress: options.macAddress).write(to: staging.appending(path: "network-config"), atomically: true, encoding: .utf8)
        if let agent = options.agentBinary {
            try FileManager.default.copyItem(at: agent, to: staging.appending(path: "macvm-agent"))
        }

        let seed = bundle.url.appending(path: seedFileName)
        try? FileManager.default.removeItem(at: seed)
        try await Subprocess.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", seed.path, staging.path])
        // user-data 里可能有明文密码，种子盘只给本用户读。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.path)
    }

    static func metaData(instanceID: String, hostname: String) -> String {
        """
        instance-id: \(instanceID)
        local-hostname: \(hostname)

        """
    }

    /// 用 MAC 作 DHCP 客户端标识：systemd-networkd 默认发 DUID，主机租约表里就查不到这台机器的 MAC。
    static func networkConfig(macAddress: String) -> String {
        """
        version: 2
        ethernets:
          primary:
            match:
              macaddress: \(yaml(macAddress.lowercased()))
            dhcp4: true
            dhcp-identifier: mac

        """
    }

    static func userData(_ o: Options) -> String {
        var mounts: [String] = []
        var runcmd: [String] = ["[systemctl, enable, --now, fstrim.timer]"]
        var writeFiles: [String] = []
        if o.agentBinary != nil {
            let agent = AgentInstaller.linuxCloudInit(user: o.user)
            writeFiles.append("  - path: /etc/systemd/system/macvm-agent.service\n    content: |\n" +
                              agent.unit.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n"))
            runcmd.append("[sh, -c, \(yaml(agent.install))]")
        }
        for share in o.shares {
            let target = share.samePath ? share.hostPath : "/mnt/\(share.tag)"
            let flags = share.readOnly ? "ro,nofail" : "rw,nofail"
            mounts.append("  - [\(yaml(share.tag)), \(yaml(target)), virtiofs, \"\(flags)\", \"0\", \"0\"]")
        }
        if o.rosetta {
            mounts.append("  - [rosetta, /media/rosetta, virtiofs, \"ro,nofail\", \"0\", \"0\"]")
            // binfmt_misc 注册 x86_64 ELF 由 Rosetta 解释执行；F 标志让注册在挂载命名空间切换后仍可用。
            runcmd.append(#"[sh, -c, "echo ':rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/media/rosetta/rosetta:CF' > /etc/binfmt.d/rosetta.conf && systemctl restart systemd-binfmt"]"#)
        }
        return """
        #cloud-config
        users:
          - name: \(yaml(o.user))
            groups: [sudo, adm]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: \(o.password == nil)
            ssh_authorized_keys:
              - \(yaml(o.sshPublicKey))
        ssh_pwauth: false
        \(o.password.map { "chpasswd:\n  expire: false\n  users:\n    - name: \(yaml(o.user))\n      password: \(yaml($0))\n      type: text" } ?? "")
        growpart:
          mode: auto
          devices: ["/"]
        \(mounts.isEmpty ? "" : "mounts:\n" + mounts.joined(separator: "\n"))
        \(writeFiles.isEmpty ? "" : "write_files:\n" + writeFiles.joined(separator: "\n"))
        runcmd:
        \(runcmd.map { "  - " + $0 }.joined(separator: "\n"))

        """
    }

    /// 作为 YAML 双引号字符串输出，避免路径或密钥里的特殊字符破坏结构。
    private static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
