public import Foundation
public import MacVMModel

/// 生成 `~/.config/macvm/ssh_config`：每台虚拟机一条 `Host macvm-<名>`，经 `macvm proxy` 连接，
/// 不依赖客户机 IP 与网络模式。由用户的 `~/.ssh/config` Include 后，ssh 与读取 ssh 配置的工具（如 runode）都能直接使用。
public enum SSHConfig {
    public static let hostPrefix = "macvm-"

    public static var fileURL: URL { SSHKeys.directory.appending(path: "ssh_config") }
    public static var userConfigURL: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config") }
    public static var includeLine: String { "Include \(fileURL.path)" }

    public static func hostAlias(for name: String) -> String { hostPrefix + name }

    /// 客户机主机密钥随重建而变，而连接只经本机 proxy 到达，所以不做主机密钥校验。
    public static func render(_ configs: [VMConfig], macvmPath: String) -> String {
        var out = "# 由 macvm 生成，会被覆盖。\n"
        for config in configs {
            out += """

            Host \(hostAlias(for: config.name))
              HostName \(config.name)
            \(config.guestUser.map { "  User \($0)\n" } ?? "")  IdentityFile \(SSHKeys.privateKeyURL.path)
              IdentitiesOnly yes
              ProxyCommand "\(macvmPath)" proxy \(config.name)
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
              LogLevel ERROR
              ServerAliveInterval 30

            """
        }
        return out
    }

    public static func write(library: VMLibrary = .default, macvmPath: String) throws -> URL {
        let configs = try library.all().compactMap { try? $0.loadConfig() }
        try FileManager.default.createDirectory(at: SSHKeys.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try render(configs, macvmPath: macvmPath).write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// 文件已存在时才更新，避免替从未启用该功能的用户写配置。
    public static func refreshIfInstalled(library: VMLibrary = .default, macvmPath: String) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        _ = try? write(library: library, macvmPath: macvmPath)
    }

    public static var isIncluded: Bool {
        guard let text = try? String(contentsOf: userConfigURL, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == includeLine }
    }

    /// 把 Include 加到 `~/.ssh/config` 最前面：Include 写在某个 Host 块之后会只对该块生效。
    public static func installInclude() throws {
        guard !isIncluded else { return }
        let dir = userConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = (try? String(contentsOf: userConfigURL, encoding: .utf8)) ?? ""
        try (includeLine + "\n\n" + existing).write(to: userConfigURL, atomically: true, encoding: .utf8)
        chmod(userConfigURL.path, 0o600)
    }
}
