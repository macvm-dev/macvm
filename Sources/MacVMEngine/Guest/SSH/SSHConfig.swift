public import Foundation
public import MacVMModel

/// 生成 `~/.config/macvm/ssh_config`：每台虚拟机一条以虚拟机名为主机名的 `Host`，经 `macvm proxy` 连接，
/// 不依赖客户机 IP 与网络模式。由用户的 `~/.ssh/config` Include 后，ssh 与读取 ssh 配置的工具（如 runode）都能直接使用。
public enum SSHConfig {
    public static var fileURL: URL { SSHKeys.directory.appending(path: "ssh_config") }
    public static var userConfigURL: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config") }
    public static var includeLine: String { "Include \(fileURL.path)" }

    /// `macvm proxy <name>` 作为 ssh 的 ProxyCommand，`flags` 接在后面。
    public static func proxyCommand(macvmPath: String, name: String, flags: [String] = []) -> String {
        (["\"\(macvmPath)\"", "proxy", name] + flags).joined(separator: " ")
    }

    /// 客户机主机密钥随重建而变，而连接只到达本机的虚拟机，所以不做主机密钥校验。
    private static let hostKeyOptions = [("StrictHostKeyChecking", "no"), ("UserKnownHostsFile", "/dev/null"), ("LogLevel", "ERROR")]

    /// 不含 IdentityFile：命令行上用 `-i` 传，路径里有空格也不会被 ssh 的选项解析拆开。
    private static func keyOptions(proxyCommand: String?) -> [(String, String)] {
        [("IdentitiesOnly", "yes")] + (proxyCommand.map { [("ProxyCommand", $0)] } ?? []) + hostKeyOptions
    }

    private static func arguments(_ options: [(String, String)]) -> [String] { options.flatMap { ["-o", "\($0)=\($1)"] } }

    /// 不校验主机密钥的 ssh 命令行选项，供用密码登录的连接使用。
    public static var hostKeyArguments: [String] { arguments(hostKeyOptions) }

    /// 用 macvm 专用密钥登录、不校验主机密钥的 ssh 命令行选项；`proxyCommand` 为 nil 时直连。
    public static func keyArguments(proxyCommand: String?) -> [String] {
        ["-i", SSHKeys.privateKeyURL.path] + arguments(keyOptions(proxyCommand: proxyCommand))
    }

    public static func render(_ configs: [VMConfig], macvmPath: String) -> String {
        var out = "# 由 macvm 生成，会被覆盖。\n"
        for config in configs {
            out += "\nHost \(config.name)\n"
            if let user = config.guestUser { out += "  User \(user)\n" }
            out += "  IdentityFile \(SSHKeys.privateKeyURL.path)\n"
            for (key, value) in keyOptions(proxyCommand: proxyCommand(macvmPath: macvmPath, name: config.name)) {
                out += "  \(key) \(value)\n"
            }
            out += "  ServerAliveInterval 30\n"
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
