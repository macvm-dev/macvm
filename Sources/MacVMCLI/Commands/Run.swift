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
            try bundle.requireNotCreating()
            let config = try bundle.loadConfig()
            let consoleMode: ConfigBuilder.Console
            if console {
                consoleMode = .fileHandles(read: .standardInput, write: .standardOutput)
            } else if detached, config.serialConsole {
                consoleMode = .fileHandles(read: nil, write: .standardOutput)
            } else {
                consoleMode = .none
            }

            let runner = try await RunnerFactory.make(bundle, console: consoleMode, display: display)
            let server = try ControlServer(runner: runner)
            defer { server.close() }
            let terminal = console ? RawTerminal() : nil
            defer { terminal?.restore() }
            let signals = SignalHandler(runner: runner)
            defer { signals.cancel() }

            if detached { log("Starting \(name) (pid \(getpid()))") }
            switch try await runner.start(recovery: recovery) {
            case .coldBoot: log("Started")
            case .restored: log("Resumed from the suspended state")
            case .restoreFailed(let reason): log("Couldn't resume from the suspended state (\(reason)); did a cold boot instead")
            }

            let reason = await runner.waitUntilStopped()
            if detached { log("Stopped: \(reason.label)") }
            if case .error(let message) = reason { throw MacVMError.engine(String(l10n: "The VM stopped unexpectedly: \(message)")) }
            return Result(reason: reason.label)
        }
    }

    /// 前台运行时只在控制台模式下保持安静，避免把日志混进客户机输出。
    private func log(_ message: String) {
        guard detached || !console else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}

/// 第一次 SIGINT/SIGTERM 请求客户机关机，第二次立即断电。
@MainActor
final class SignalHandler {
    private var sources: [any DispatchSourceSignal] = []
    private var requested = false

    init(runner: any MachineRunner) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self, weak runner] in
                MainActor.assumeIsolated {
                    guard let self, let runner else { return }
                    if !self.requested, (try? runner.requestStop()) != nil {
                        self.requested = true
                        FileHandle.standardError.write(Data(("\n" + String(l10n: "Asked the guest to shut down. Press Ctrl-C again to power off immediately.") + "\n").utf8))
                    } else {
                        Task { try? await runner.forceStop() }
                    }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
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
