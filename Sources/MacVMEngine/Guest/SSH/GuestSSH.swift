public import Foundation
public import MacVMModel

/// 用密码登录一次客户机，把 macvm 专用公钥追加进 `authorized_keys`，之后的连接都走密钥。
public enum GuestSSH {
    public static func installPublicKey(bundle: VMBundle, user: String, password: String, proxyCommand: String, timeout: TimeInterval) async throws {
        let key = try await SSHKeys.ensurePublicKey()
        let askpass = FileManager.default.temporaryDirectory.appending(path: "macvm-askpass-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' \"$MACVM_GUEST_PASSWORD\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        defer { try? FileManager.default.removeItem(at: askpass) }

        let remote = "umask 077; mkdir -p ~/.ssh && grep -qxF '\(key)' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\\n' '\(key)' >> ~/.ssh/authorized_keys"
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["MACVM_GUEST_PASSWORD"] = password

        let deadline = Date().addingTimeInterval(timeout)
        var lastError = ""
        while Date() < deadline {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ssh")
            process.arguments = ["-o", "ProxyCommand=\(proxyCommand)", "-o", "PubkeyAuthentication=no",
                                 "-o", "PreferredAuthentications=keyboard-interactive,password"] + SSHConfig.hostKeyArguments
                                + ["-o", "ConnectTimeout=10", "-o", "NumberOfPasswordPrompts=1",
                                 "\(user)@\(bundle.name)", remote]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
            lastError = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.sleep(for: .seconds(5))
        }
        throw MacVMError.timeout("未能登录 \(bundle.name) 装入 SSH 公钥：\(lastError)")
    }
}
