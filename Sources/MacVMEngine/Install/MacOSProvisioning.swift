public import Foundation
public import MacVMModel
@preconcurrency import Virtualization

/// macOS 客户机首次开机的自动开通：建用户、自动登录、开 SSH，跳过设置助理。
///
/// 安装时把凭据写进包内 `provisioning.json`（0600），首次 `start` 交给 VZ 后删除。
public enum MacOSProvisioning {
    public struct Credentials: Codable, Sendable {
        public var user: String
        public var password: String
    }

    static func pendingURL(_ bundle: VMBundle) -> URL { bundle.url.appending(path: "provisioning.json") }

    static func schedule(_ credentials: Credentials, in bundle: VMBundle) throws {
        try GuestCredentials.writePrivate(JSONEncoder().encode(credentials), to: pendingURL(bundle))
        try GuestCredentials.storePassword(credentials.password, in: bundle)
    }

    /// 有待开通的凭据且系统支持时，写入启动选项并返回 true。
    @available(macOS 27, *)
    static func apply(to options: VZMacOSVirtualMachineStartOptions, bundle: VMBundle) throws -> Bool {
        guard let data = try? Data(contentsOf: pendingURL(bundle)) else { return false }
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = credentials.user
        provisioning.username = credentials.user
        provisioning.password = credentials.password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true
        try options.setGuestProvisioning(provisioning)
        return true
    }

    static func markApplied(_ bundle: VMBundle) {
        try? FileManager.default.removeItem(at: pendingURL(bundle))
    }

}

/// 客户机登录密码，存在包内 `guest-password`（0600），供用密码登录装入 SSH 公钥及用户自行查看。
public enum GuestCredentials {
    public static func passwordURL(_ bundle: VMBundle) -> URL { bundle.url.appending(path: "guest-password") }

    public static func password(for bundle: VMBundle) -> String? {
        (try? String(contentsOf: passwordURL(bundle), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func storePassword(_ password: String, in bundle: VMBundle) throws {
        try writePrivate(Data(password.utf8), to: passwordURL(bundle))
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<4).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: url)
    }
}
