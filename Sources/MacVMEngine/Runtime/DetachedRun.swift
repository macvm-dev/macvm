import Foundation
public import MacVMModel

/// 在独立的后台进程里运行虚拟机，与派生它的终端或 App 脱离，它们退出后虚拟机照样运行。
/// 后台进程是 `macvm run <名字> --detached`；桥接网络要 `Entitlements.vmNetworking`，只有 App 主程序带得了，桥接的虚拟机改由它带 `appRunArgument` 运行。
public enum DetachedRun {
    /// App 主程序的隐藏参数，后跟虚拟机名：不起界面，在本进程里运行这台虚拟机直到它停止。
    static let appRunArgument = "--run-detached"

    /// 进程参数（含程序路径）里 `appRunArgument` 后面的虚拟机名；没有这个参数或缺名字时为 nil。
    public static func appRunTarget(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: appRunArgument), index + 1 < arguments.count else { return nil }
        let name = arguments[index + 1]
        return name.hasPrefix("-") ? nil : name
    }

    /// 后台进程的主体：开机、监听控制 socket，直到虚拟机停止。有挂起状态时从它恢复。
    /// 启停记录写标准错误；开了 `VMConfig.serialConsole` 时控制台输出写标准输出。调用方要让主线程的 RunLoop 一直运转。
    @MainActor
    public static func serve(_ bundle: VMBundle) async throws -> MachineStopReason {
        try bundle.requireNotCreating()
        let config = try bundle.loadConfig()
        let console: ConfigBuilder.Console = config.serialConsole ? .fileHandles(read: nil, write: .standardOutput) : .none

        let runner = try await RunnerFactory.make(bundle, console: console)
        let server = try ControlServer(runner: runner)
        defer { server.close() }
        let signals = SignalHandler(runner: runner)
        defer { signals.cancel() }

        log("Starting \(bundle.name) (pid \(getpid()))")
        switch try await runner.start(recovery: false) {
        case .coldBoot: log("Started")
        case .restored: log("Resumed from the suspended state")
        case .restoreFailed(let reason): log("Couldn't resume from the suspended state (\(reason)); did a cold boot instead")
        }
        // 端口被占这类失败不影响开机，只记进日志。
        if let error = await Task.detached(operation: { server.applyForwards() }).value { log("Port forwarding: \(error.message)") }

        let reason = await runner.waitUntilStopped()
        log("Stopped: \(reason.label)")
        return reason
    }

    /// 用 `executable`（macvm CLI）派生后台进程，等到虚拟机进入 running。后台进程由 `command(for:cli:hasEntitlement:)` 决定。
    public static func launch(_ bundle: VMBundle, executable: String, timeout: Int) async throws -> VMSummary {
        let name = bundle.name
        let command = try command(for: bundle, cli: executable)
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: bundle.logURL.path)[.size] as? UInt64) ?? 0
        let pid = try spawn(command.executable, arguments: command.arguments, log: bundle.logURL)

        let ready = try await VMStatus.poll(timeout: TimeInterval(timeout)) {
            if hasExited(pid) {
                let tail = readLog(bundle.logURL, from: logOffset)
                throw MacVMError.engine(String(l10n: "Couldn't start the background process: \(tail.isEmpty ? String(l10n: "no output") : tail)"))
            }
            guard let status = try? ControlClient.send(.status, to: bundle, timeout: 2) else { return false }
            return status.ok && status.state == "running"
        }
        guard ready else { throw MacVMError.timeout(String(l10n: "Timed out waiting for \(name) to start; see the log at \(bundle.logURL.path)")) }
        return try VMStatus.summary(of: bundle)
    }

    /// 后台进程的程序与参数。桥接网络的虚拟机要求 `cli`（解析符号链接后）是某个 App 包里的 `Contents/Resources/bin/macvm`，
    /// 且该包主程序的签名带 `Entitlements.vmNetworking`，否则报 `MacVMError.entitlementMissing`。
    /// `hasEntitlement` 判断某个可执行文件的签名里有没有给定的 entitlement。
    static func command(
        for bundle: VMBundle, cli: String,
        hasEntitlement: (String, URL) -> Bool = Entitlements.has(_:inExecutableAt:)
    ) throws -> (executable: String, arguments: [String]) {
        let name = bundle.name
        guard try bundle.loadConfig().networks.first?.mode == .bridged else { return (cli, ["run", name, "--detached"]) }

        let resolved = URL(filePath: cli).resolvingSymlinksInPath()
        let components = resolved.pathComponents
        if components.suffix(4) == ["Contents", "Resources", "bin", "macvm"],
           components.dropLast(4).last?.hasSuffix(".app") == true,
           let app = Bundle(url: resolved.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()),
           let executable = app.executableURL,
           hasEntitlement(Entitlements.vmNetworking, executable) {
            return (executable.path, [appRunArgument, name])
        }
        throw MacVMError.entitlementMissing(String(l10n: "\(name) uses bridged networking, which only runs in the MacVM app signed for it. Use the macvm inside that app, or start it in the app."))
    }

    /// 时间戳加消息，写标准错误。
    private static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
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
        guard rc == 0 else { throw MacVMError.posix(String(l10n: "Couldn't spawn the background process"), code: rc) }
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
