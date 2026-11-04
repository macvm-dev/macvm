import CryptoKit
public import Foundation
public import MacVMModel

/// 宿主与 Linux、Windows 客户机代理共享的令牌：客户机里有令牌时，代理对经 TCP 连入的连接
/// 都要宿主答对以它为密钥的质询（`AgentToken.authenticate`）才受理请求，vsock 连接不用。
/// 宿主这边存在包内 `agent-token`（0600）；客户机里的副本只有 root（Linux）或 SYSTEM 与管理员（Windows）能读，
/// 不能出现在客户机进程的命令行里，否则客户机里的普通用户能读到它，再以代理的身份执行命令。
public enum AgentToken {
    public static func url(_ bundle: VMBundle) -> URL { bundle.url.appending(path: "agent-token") }
    static let linuxPath = "/etc/macvm-agent/token"
    static let windowsPath = AgentInstaller.windowsDirectory + #"\agent-token"#

    static func read(_ bundle: VMBundle) -> String? {
        let text = (try? String(contentsOf: url(bundle), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func random() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    static func store(_ token: String, in bundle: VMBundle) throws {
        try GuestCredentials.writePrivate(Data(token.utf8), to: url(bundle))
    }

    /// 包里没有令牌时生成一个存下。
    static func ensure(_ bundle: VMBundle) throws -> String {
        if let token = read(bundle) { return token }
        let token = random()
        try store(token, in: bundle)
        return token
    }

    // MARK: - 质询应答

    private struct Challenge: Decodable { let challenge: String }
    private struct Answer: Encodable { let auth: String }

    static func answer(token: String, challenge: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: Data(token.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 经 TCP 连上代理端口后调用：包里有令牌就过质询。没有令牌时代理只受理来自默认网关的连接，
    /// 宿主在桥接网络下不是默认网关（`bridged`），这时直接报错。
    static func authenticate(_ socket: UnixSocket, bundle: VMBundle, bridged: Bool) throws {
        guard let token = read(bundle) else {
            guard !bridged else {
                throw MacVMError.invalidConfig("\(bundle.name) 的包里没有共享令牌，桥接网络下连不上客户机代理，用 macvm agent install \(bundle.name) 重新安装代理")
            }
            return
        }
        try authenticate(socket, token: token, name: bundle.name)
    }

    /// 在 `socket` 上读质询、回应答。令牌不对时代理回错误后断开，表现为随后那个请求失败。
    static func authenticate(_ socket: UnixSocket, token: String, name: String) throws {
        socket.setTimeout(seconds: 10)
        defer { socket.setTimeout(seconds: 0) }
        guard let line = try socket.readLine(exact: true) else {
            throw MacVMError.engine("\(name) 的客户机代理没有发来认证质询就断开了：代理没在运行，或客户机里没有共享令牌（用 macvm agent install \(name) 重新安装代理）")
        }
        guard let challenge = try? JSONDecoder().decode(Challenge.self, from: line).challenge else {
            throw MacVMError.engine("\(name) 的客户机代理没有发来认证质询，可能是旧版代理，用 macvm agent install \(name) 更新")
        }
        try socket.writeLine(JSONEncoder().encode(Answer(auth: answer(token: token, challenge: challenge))))
    }

    // MARK: - 放进客户机

    /// Linux 上以 root 写入令牌的命令，令牌从标准输入读入；`root` 是目标系统的根目录（安装环境里挂在别处）。
    static func linuxInstallCommand(root: String = "") -> String {
        "umask 077 && mkdir -p \(root)\((linuxPath as NSString).deletingLastPathComponent) && cat > \(root)\(linuxPath)"
    }

    /// Windows 上写入令牌的 PowerShell 片段，要在 `AgentInstaller.windowsPrepareDirectory` 之后运行：
    /// 文件继承那个目录只给 SYSTEM 与 Administrators 的权限。
    /// 片段以管理员身份运行，命令行只有同一用户的提升进程与管理员能读。
    static func windowsInstall(_ token: String) -> String {
        "[IO.File]::WriteAllText(\(PowerShell.quote(windowsPath)), \(PowerShell.quote(token)))"
    }
}
