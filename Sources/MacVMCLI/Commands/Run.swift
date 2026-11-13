import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Run a VM headless in the foreground until the guest shuts down."),
        discussion: String(l10n: "Ctrl-C asks the guest to shut down; press it again to power off immediately. --console connects the guest console (hvc0) to the current terminal.")
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    @Flag(help: ArgumentHelp(String(l10n: "Connect the guest's virtio console to stdin and stdout.")))
    var console = false

    @Flag(help: ArgumentHelp(String(l10n: "Start in recovery mode (macOS guests).")))
    var recovery = false

    @Flag(help: ArgumentHelp(String(l10n: "Show the screen in a QEMU window (QEMU engine).")))
    var display = false

    /// 作为后台进程运行：标准输出与标准错误是 `VMBundle.logURL`，启停记录与开了 `VMConfig.serialConsole` 时的控制台输出都写进去。
    @Flag(help: .hidden)
    var detached = false

    struct Result: Encodable, Sendable { let reason: String }

    @MainActor
    func run() async throws {
        try await Output.run(json: global.json, human: { (r: Result) in detached ? String(l10n: "VM stopped: \(r.reason)") : nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let reason = detached ? try await DetachedRun.serve(bundle) : try await runInForeground(bundle)
            if case .error(let message) = reason { throw MacVMError.engine(String(l10n: "The VM stopped unexpectedly: \(message)")) }
            return Result(reason: reason.label)
        }
    }

    @MainActor
    private func runInForeground(_ bundle: VMBundle) async throws -> MachineStopReason {
        try bundle.requireNotCreating()
        let config = try bundle.loadConfig()
        // 桥接只有 App 主程序跑得了，开机前就指明可行的途径。
        if config.networks.first?.mode == .bridged, !NetworkAttachments.canBridge {
            throw MacVMError.entitlementMissing(String(l10n: "\(bundle.name) uses bridged networking, which macvm run can't provide in the foreground. Use macvm start, or start it in the MacVM app."))
        }
        let consoleMode: ConfigBuilder.Console = console ? .fileHandles(read: .standardInput, write: .standardOutput) : .none

        let runner = try await RunnerFactory.make(bundle, console: consoleMode, display: display)
        let server = try ControlServer(runner: runner)
        defer { server.close() }
        let terminal = console ? RawTerminal() : nil
        defer { terminal?.restore() }
        let signals = SignalHandler(runner: runner)
        defer { signals.cancel() }

        switch try await runner.start(recovery: recovery) {
        case .coldBoot: log("Started")
        case .restored: log("Resumed from the suspended state")
        case .restoreFailed(let reason): log("Couldn't resume from the suspended state (\(reason)); did a cold boot instead")
        }
        // 端口被占这类失败不影响开机，只记进日志。
        if let error = await Task.detached(operation: { server.applyForwards() }).value { log("Port forwarding: \(error.message)") }

        return await runner.waitUntilStopped()
    }

    /// 控制台模式下保持安静，避免把日志混进客户机输出。
    private func log(_ message: String) {
        guard !console else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}

/// 把终端切成 raw，按键原样送进客户机。
final class RawTerminal {
    private var original = termios()
    private let active: Bool

    /// `passSignals` 为 true 时保留 ISIG，Ctrl-C 由本进程处理；否则作为普通字节交给客户机。
    init(passSignals: Bool = true) {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            active = false
            return
        }
        var raw = original
        cfmakeraw(&raw)
        if passSignals { raw.c_lflag |= tcflag_t(ISIG) }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        active = true
    }

    func restore() {
        guard active else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }
}
