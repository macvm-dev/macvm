import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "在后台启动虚拟机，启动完成后返回。",
        discussion: "后台进程的日志写在虚拟机包内的 run.log。"
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "虚拟机名称。") var name: String

    @Option(help: "等待启动完成的最长秒数。")
    var timeout: Int = 60

    func run() async throws {
        try await Output.run(json: global.json, human: { (s: VMSummary) in "\(s.name) 已在后台运行（pid \(s.pid.map(String.init) ?? "?")）" }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            if BundleLock.holder(of: bundle) != nil { throw MacVMError.alreadyRunning(name) }
            return try await Self.launch(bundle, timeout: timeout)
        }
    }

    /// 派生后台进程并等到虚拟机进入 running。
    static func launch(_ bundle: VMBundle, timeout: Int) async throws -> VMSummary {
        let name = bundle.name
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: bundle.logURL.path)[.size] as? UInt64) ?? 0
        let pid = try Detach.spawn(arguments: ["run", name, "--detached"], log: bundle.logURL)

        let ready = try await VMStatus.poll(timeout: TimeInterval(timeout)) {
            if Detach.hasExited(pid) {
                let tail = Detach.readLog(bundle.logURL, from: logOffset)
                throw MacVMError.engine("后台进程启动失败：\(tail.isEmpty ? "无输出" : tail)")
            }
            guard let status = try? ControlClient.send(.status, to: bundle, timeout: 2) else { return false }
            return status.ok && status.state == "running"
        }
        guard ready else { throw MacVMError.timeout("等待 \(name) 启动超时，日志：\(bundle.logURL.path)") }
        return try VMStatus.summary(of: bundle)
    }
}

enum Detach {
    /// 以新会话派生自身，脱离当前终端：终端关闭不会让虚拟机收到 SIGHUP。
    static func spawn(arguments: [String], log: URL) throws -> pid_t {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
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

    static func hasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }

    static func readLog(_ url: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
