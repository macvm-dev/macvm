public import Foundation
public import MacVMModel

/// 用密码登录一次客户机，把 macvm 专用公钥追加进 `authorized_keys`，之后的连接都走密钥。
public enum GuestSSH {
    public static func installPublicKey(bundle: VMBundle, user: String, password: String, proxyCommand: String, timeout: TimeInterval) async throws {
        try SSHConfig.validateLogin(user: user, host: bundle.name)
        let key = try await SSHKeys.ensurePublicKey()
        let askpass = try makeAskpass()
        defer { try? FileManager.default.removeItem(at: askpass) }

        let remote = "umask 077; mkdir -p ~/.ssh && grep -qxF '\(key)' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\\n' '\(key)' >> ~/.ssh/authorized_keys"
        let environment = askpassEnvironment(askpass, password: password)

        let deadline = Date().addingTimeInterval(timeout)
        var lastError = ""
        while Date() < deadline {
            // 每次 ssh 都起一个 ProxyCommand，虚拟机没在运行时它会把虚拟机拉起来：取消后不再发起。
            try Task.checkCancellation()
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
            if try await run(process) == 0 { return }
            lastError = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.sleep(for: .seconds(5))
        }
        throw MacVMError.timeout(String(l10n: "Couldn't log in to \(bundle.name) to install the SSH public key: \(lastError)"))
    }

    /// 运行 `process` 并等它退出，返回退出码；任务取消时终止它并抛出 `CancellationError`。
    private static func run(_ process: Process) async throws -> Int32 {
        let running = RunningProcess(process)
        ChildProcesses.register(running)
        defer { ChildProcesses.unregister(running) }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    c.resume(throwing: error)
                    return
                }
                // 取消发生在 run 之前时 onCancel 看不到在运行的进程，这里补上。
                if Task.isCancelled { running.terminate() }
            }
        } onCancel: {
            running.terminate()
        }
        try Task.checkCancellation()
        return status
    }

    /// 新建一个 SSH_ASKPASS 脚本，它输出 `askpassEnvironment` 放进环境的密码；调用方用完删除。
    static func makeAskpass() throws -> URL {
        let askpass = FileManager.default.temporaryDirectory.appending(path: "macvm-askpass-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' \"$MACVM_GUEST_PASSWORD\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        return askpass
    }

    /// 让 ssh 不经终端、改由 `askpass` 回答密码提示的进程环境。
    static func askpassEnvironment(_ askpass: URL, password: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["MACVM_GUEST_PASSWORD"] = password
        return environment
    }
}
