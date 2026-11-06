import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: String(l10n: "Run a command in the guest and exit with its exit code."),
        discussion: String(l10n: """
        Starts the VM in the background if it isn't running. Examples:
          macvm exec dev -- uname -a
          macvm exec dev -t --cwd "$PWD" -- claude
        """)
    )

    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    @Flag(name: .shortAndLong, help: ArgumentHelp(String(l10n: "Allocate a pseudo-terminal (needed for interactive programs).")))
    var tty = false

    @Option(help: ArgumentHelp(String(l10n: "Working directory in the guest.")))
    var cwd: String?

    @Argument(parsing: .postTerminator, help: ArgumentHelp(String(l10n: "Command to run.")))
    var command: [String] = []

    @Option(help: ArgumentHelp(String(l10n: "Run as this guest user (Linux guests only, where the agent runs as root).")))
    var user: String?

    func run() async throws {
        try await Output.run(json: false, human: { (_: Empty) in nil }) {
            let bundle = try VMLibrary.default.bundle(named: name)
            let config = try bundle.loadConfig()
            if config.guestAgent {
                try await Wait.untilReady(bundle, config: config, timeout: 120)
                let interactive = tty || command.isEmpty
                let size = interactive ? TerminalSize.current() : nil
                let argv = command.isEmpty ? ["/bin/sh", "-c", "exec \"$SHELL\" -l"] : command
                let request = AgentProtocol.ExecRequest(argv: argv, user: user, cwd: cwd, tty: interactive, cols: size?.cols, rows: size?.rows)
                let terminal = interactive ? RawTerminal(passSignals: false) : nil
                defer { terminal?.restore() }
                let code = try AgentClient.exec(bundle, request: request)
                throw ExitCode(code)
            }
            if user != nil {
                throw MacVMError.unsupported(String(l10n: "--user needs the guest agent, which isn't installed on \(name)"))
            }
            try await Wait.untilReady(bundle, config: config, timeout: 300)
            let remote = config.os == .windows ? Self.powerShellCommand(command, cwd: cwd) : Self.posixCommand(command, cwd: cwd)
            try SSH.execSSH(config: config, tty: tty || command.isEmpty, remoteCommand: remote)
        }
    }

    static func posixCommand(_ argv: [String], cwd: String?) -> String? {
        var remote = argv.map(shellQuote).joined(separator: " ")
        if let cwd { remote = "cd \(shellQuote(cwd)) && " + (remote.isEmpty ? "exec \"$SHELL\" -l" : "exec \(remote)") }
        return remote.isEmpty ? nil : remote
    }

    /// Windows 客户机的 sshd 默认 shell 是 PowerShell：以调用运算符执行，参数用单引号字面量。
    static func powerShellCommand(_ argv: [String], cwd: String?) -> String? {
        var parts: [String] = []
        if let cwd { parts.append("Set-Location -LiteralPath \(PowerShell.quote(cwd))") }
        if !argv.isEmpty { parts.append("& " + argv.map(PowerShell.quote).joined(separator: " ") + "; exit $LASTEXITCODE") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: String(l10n: "Open a login shell in the guest."), discussion: String(l10n: "Starts the VM in the background if it isn't running."))

    @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String

    func run() async throws {
        try await Output.run(json: false, human: { (_: Empty) in nil }) {
            let config = try VMLibrary.default.bundle(named: name).loadConfig()
            try await Wait.untilReady(VMLibrary.default.bundle(named: name), config: config, timeout: 120)
            try Self.execSSH(config: config, tty: true, remoteCommand: nil)
        }
    }

    /// 用 macvm 专用密钥与 `macvm proxy` 替换当前进程为 ssh，退出码直接是 ssh（即客户机命令）的退出码。
    static func execSSH(config: VMConfig, tty: Bool, remoteCommand: String?) throws -> Never {
        guard let user = config.guestUser else {
            throw MacVMError.unsupported(String(l10n: "macvm doesn't know the login user for \(config.name) (for VMs installed from installation media, set up SSH yourself)"))
        }
        try SSHConfig.validateLogin(user: user, host: config.name)
        let proxy = SSHConfig.proxyCommand(macvmPath: SSHConfigCommand.executablePath, name: config.name)
        var args = ["ssh", "-q", tty ? "-tt" : "-T"] + SSHConfig.keyArguments(proxyCommand: proxy)
            + ["\(user)@\(config.name)"]
        if let remoteCommand { args += ["--", remoteCommand] }
        let argv = args.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", argv)
        throw MacVMError.posix(String(l10n: "Couldn't run ssh"))
    }
}
