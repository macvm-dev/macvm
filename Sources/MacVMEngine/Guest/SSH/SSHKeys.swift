public import Foundation
import MacVMModel

/// macvm 专用的 SSH 密钥对，注入每台新建的客户机，`macvm ssh-config` 生成的配置也指向它。
public enum SSHKeys {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/macvm", directoryHint: .isDirectory)
    }

    public static var privateKeyURL: URL { directory.appending(path: "id_ed25519") }
    public static var publicKeyURL: URL { directory.appending(path: "id_ed25519.pub") }

    /// 返回公钥内容，密钥不存在时生成。
    public static func ensurePublicKey() async throws -> String {
        if !FileManager.default.fileExists(atPath: privateKeyURL.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await Subprocess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "macvm", "-f", privateKeyURL.path])
        }
        return try String(contentsOf: publicKeyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
