import Foundation
public import MacVMModel

/// 按 `VMConfig.screenLock` 设定客户机空闲、显示器休眠后是否锁屏。经代理 `exec` 执行，可重复执行；
/// 关锁屏只改锁屏本身，显示器照常按节能设置休眠。
public enum GuestScreenLock {
    /// 在运行中的 `bundle` 里按 `config.screenLock` 设好。没装代理、代理没上线、macOS 客户机没有保存的密码，
    /// 或客户机里的命令失败时抛错。阻塞的 socket 往返，不要在主线程上调用。
    public static func apply(_ bundle: VMBundle, config: VMConfig) throws {
        guard config.guestAgent else {
            throw MacVMError.unsupported("\(config.name) 没有装客户机代理，锁屏设置要等装上代理后才能写进客户机")
        }
        let (request, input) = try command(locks: config.screenLock, os: config.os, bundle: bundle)
        let (code, output) = try AgentClient.run(bundle, request: request, input: input, timeout: commandTimeout)
        guard code == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = code.map { "退出码 \($0)" } ?? "代理中途断开"
            throw MacVMError.engine("设置 \(config.name) 的客户机锁屏失败（\(status)）" + (detail.isEmpty ? "" : "：\(detail)"))
        }
    }

    /// 开机后等代理上线再 `apply`，届时重读配置；没装代理时返回 nil。代理在客户机登录后才启动，开机慢时要等好几分钟。
    /// 失败只写到标准错误。
    static func applyAfterBoot(_ bundle: VMBundle, config: VMConfig) -> Task<Void, Never>? {
        guard config.guestAgent else { return nil }
        return Task.detached {
            for _ in 0..<agentWaitAttempts {
                if Task.isCancelled { return }
                if AgentClient.isReachable(bundle) {
                    do { try apply(bundle, config: bundle.loadConfig()) } catch {
                        FileHandle.standardError.write(Data("macvm: \((error as? MacVMError)?.message ?? "\(error)")\n".utf8))
                    }
                    return
                }
                try? await Task.sleep(for: agentWaitInterval)
            }
        }
    }

    private static let agentWaitAttempts = 120
    private static let agentWaitInterval: Duration = .seconds(5)
    private static let commandTimeout = 60

    static func command(locks: Bool, os: GuestOS, bundle: VMBundle) throws -> (AgentProtocol.ExecRequest, Data) {
        switch os {
        case .macOS:
            // sysadminctl 要当前用户的登录密码，经标准输入送进去，不出现在客户机的进程参数里。
            guard let password = GuestCredentials.password(for: bundle) else {
                throw MacVMError.unsupported("\(bundle.name) 没有保存客户机密码，macOS 改锁屏设置要用登录密码")
            }
            let script = """
            IFS= read -r password
            exec sysadminctl -screenLock \(locks ? "immediate" : "off") -password "$password"
            """
            return (.init(argv: ["/bin/sh", "-c", script]), Data((password + "\n").utf8))
        case .linux:
            return (.init(argv: ["/bin/sh", "-c", linuxScript(locks: locks)]), Data())
        case .windows:
            // 「离开后何时要求重新登录」：CONSOLELOCK 为 0 时唤醒不再要求登录。
            let script = """
            foreach ($flag in '/setacvalueindex', '/setdcvalueindex') {
              powercfg $flag SCHEME_CURRENT SUB_NONE CONSOLELOCK \(locks ? 1 : 0)
              if ($LASTEXITCODE) { throw "powercfg exited with $LASTEXITCODE" }
            }
            powercfg /setactive SCHEME_CURRENT
            if ($LASTEXITCODE) { throw "powercfg exited with $LASTEXITCODE" }
            """
            return (PowerShell.exec(script), Data())
        }
    }

    /// 以 root 运行：GNOME 的系统默认设置管之后登录的会话，已登录的会话以会话用户身份接上它的会话总线立即改。
    /// 没有 GNOME（没有 dconf、gsettings）的客户机什么都不做。
    static func linuxScript(locks: Bool) -> String {
        let value = locks ? "true" : "false"
        return """
        set -u
        if command -v dconf >/dev/null 2>&1; then
          mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
          [ -f /etc/dconf/profile/user ] || printf 'user-db:user\\nsystem-db:local\\n' > /etc/dconf/profile/user
          printf '%s\\n' '[org/gnome/desktop/screensaver]' 'lock-enabled=\(value)' 'ubuntu-lock-on-suspend=\(value)' > /etc/dconf/db/local.d/95-macvm-screen-lock
          dconf update || exit 1
        fi
        command -v gsettings >/dev/null 2>&1 || exit 0
        for bus in /run/user/*/bus; do
          [ -S "$bus" ] || continue
          uid=${bus#/run/user/}; uid=${uid%/bus}
          user=$(id -nu "$uid" 2>/dev/null) || continue
          for key in lock-enabled ubuntu-lock-on-suspend; do
            runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="/run/user/$uid" \\
              gsettings set org.gnome.desktop.screensaver "$key" \(value) 2>/dev/null || true
          done
        done
        """
    }
}
