import ArgumentParser
import Foundation
import MacVMEngine
import MacVMModel

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "在客户机里执行命令，退出码与客户机命令一致。",
        discussion: """
        虚拟机未运行时自动在后台启动。示例：
          macvm exec dev -- uname -a
          macvm exec dev -t --cwd "$PWD" -- claude
        """
    )

    @Argument(help: "虚拟机名称。") var name: String

    @Flag(name: .shortAndLong, help: "分配伪终端（交互程序需要）。")
    var tty = false

    @Option(help: "在客户机的该目录下执行。")
    var cwd: String?

    @Argument(parsing: .postTerminator, help: "要执行的命令。")
    var command: [String] = []

    @Option(help: "以该客户机用户执行（需代理以 root 运行，即 Linux 客户机）。")
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
                let code = try AgentClient.exec(bundle, request: request)
                terminal?.restore()
                throw ExitCode(code)
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
        if let cwd { parts.append("Set-Location -LiteralPath \(powerShellQuote(cwd))") }
        if !argv.isEmpty { parts.append("& " + argv.map(powerShellQuote).joined(separator: " ") + "; exit $LASTEXITCODE") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func powerShellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "打开客户机的登录 shell。", discussion: "虚拟机未运行时自动在后台启动。")

    @Argument(help: "虚拟机名称。") var name: String

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
            throw MacVMError.unsupported("不知道 \(config.name) 的登录用户（从安装介质安装的虚拟机需自行配置 SSH）")
        }
        let proxy = "\"\(SSHConfigCommand.executablePath)\" proxy \(config.name)"
        // 未装代理时 sshd 走 NAT 网络；先确保虚拟机在运行，免得 ssh 的连接超时先于开机完成。
        var args = ["ssh", "-q", tty ? "-tt" : "-T",
                    "-i", SSHKeys.privateKeyURL.path, "-o", "IdentitiesOnly=yes",
                    "-o", "ProxyCommand=\(proxy)",
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                    "\(user)@\(SSHConfig.hostAlias(for: config.name))"]
        if let remoteCommand { args += ["--", remoteCommand] }
        let argv = args.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", argv)
        throw MacVMError.io("无法执行 ssh：\(String(cString: strerror(errno)))")
    }
}
