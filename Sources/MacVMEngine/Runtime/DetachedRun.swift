import Foundation
public import MacVMModel

/// 在独立的后台进程里运行虚拟机：派生 `macvm run <名字> --detached`，与派生它的终端或 App 脱离，它们退出后虚拟机照样运行。
public enum DetachedRun {
    /// 用 `executable`（macvm CLI）派生后台进程，等到虚拟机进入 running。有挂起状态时后台进程从它恢复。
    public static func launch(_ bundle: VMBundle, executable: String, timeout: Int) async throws -> VMSummary {
        let name = bundle.name
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: bundle.logURL.path)[.size] as? UInt64) ?? 0
        let pid = try spawn(executable, arguments: ["run", name, "--detached"], log: bundle.logURL)

        let ready = try await VMStatus.poll(timeout: TimeInterval(timeout)) {
            if hasExited(pid) {
                let tail = readLog(bundle.logURL, from: logOffset)
                throw MacVMError.engine("后台进程启动失败：\(tail.isEmpty ? "无输出" : tail)")
            }
            guard let status = try? ControlClient.send(.status, to: bundle, timeout: 2) else { return false }
            return status.ok && status.state == "running"
        }
        guard ready else { throw MacVMError.timeout("等待 \(name) 启动超时，日志：\(bundle.logURL.path)") }
        return try VMStatus.summary(of: bundle)
    }

    /// 以新会话派生：终端关闭不会让虚拟机收到 SIGHUP。不继承派生方的文件描述符。
    private static func spawn(_ executable: String, arguments: [String], log: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, environ)
        guard rc == 0 else { throw MacVMError.posix("派生后台进程", code: rc) }
        return pid
    }

    private static func hasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }

    private static func readLog(_ url: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
