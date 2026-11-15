import Foundation
public import MacVMModel

/// 按 `VMConfig.screenLock` 设定客户机空闲后是否熄屏并锁屏。经代理 `exec` 执行，可重复执行。
/// 锁屏要等客户机空闲才触发：开锁屏时客户机没有空闲时限的，设成 `displaySleepMinutes`、`linuxIdleDelaySeconds`，
/// 已有的时限不动；关锁屏时连熄屏一起关掉，熄屏只省下出画面的开销。
public enum GuestScreenLock {
    /// 在运行中的 `bundle` 里按 `config.screenLock` 设好。没装代理、代理没上线、macOS 客户机没有保存的密码，
    /// 或客户机里的命令失败时抛错。阻塞的 socket 往返，不要在主线程上调用。
    public static func apply(_ bundle: VMBundle, config: VMConfig) throws {
        guard config.guestAgent else {
            throw MacVMError.unsupported(String(l10n: "The guest agent isn't installed in \(config.name); install it to apply screen lock settings"))
        }
        let (request, input) = try command(locks: config.screenLock, os: config.os, bundle: bundle)
        let (code, output) = try AgentClient.run(bundle, request: request, input: input, timeout: commandTimeout)
        guard code == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = code.map { String(l10n: "exit code \($0)") } ?? String(l10n: "the guest agent disconnected")
            throw MacVMError.engine(String(l10n: "Couldn't set the screen lock in \(config.name) (\(status))") + (detail.isEmpty ? "" : String(l10n: ": \(detail)")))
        }
    }

    /// 开机后经 `AgentClient.afterOnline` 执行 `apply`，每次都重读配置；没装代理时返回 nil。
    static func applyAfterBoot(_ bundle: VMBundle, config: VMConfig) -> Task<Void, Never>? {
        guard config.guestAgent else { return nil }
        return AgentClient.afterOnline(bundle) { try apply(bundle, config: bundle.loadConfig()) }
    }

    private static let commandTimeout = 60
    static let displaySleepMinutes = 10
    static let linuxIdleDelaySeconds = 300

    static func command(locks: Bool, os: GuestOS, bundle: VMBundle) throws -> (AgentProtocol.ExecRequest, Data) {
        switch os {
        case .macOS:
            // sysadminctl 与改熄屏的 sudo 都要当前用户的登录密码，经标准输入送进去，不出现在客户机的进程参数里。
            guard let password = GuestCredentials.password(for: bundle) else {
                throw MacVMError.unsupported(String(l10n: "No guest password is saved for \(bundle.name); changing the screen lock on macOS needs the login password"))
            }
            let displaySleep = locks
                ? #"[ "$(pmset -g | awk '$1 == "displaysleep" { print $2 }')" = 0 ] || exit 0"# + "\nminutes=\(displaySleepMinutes)"
                : "minutes=0"
            let script = """
            IFS= read -r password
            sysadminctl -screenLock \(locks ? "immediate" : "off") -password "$password" || exit
            \(displaySleep)
            printf '%s\\n' "$password" | sudo -S -p '' pmset -a displaysleep "$minutes"
            """
            return (.init(argv: ["/bin/sh", "-c", script]), Data((password + "\n").utf8))
        case .linux:
            return (.init(argv: ["/bin/sh", "-c", linuxScript(locks: locks)]), Data())
        case .windows:
            return (PowerShell.exec(windowsScript(locks: locks)), Data())
        }
    }

    /// 以登录用户身份在其会话里运行。熄屏不会让 Windows 锁屏，空闲锁屏靠带「恢复时显示登录屏幕」的屏保，
    /// 经 `SystemParametersInfo`（`SPIF_UPDATEINIFILE | SPIF_SENDCHANGE`）设置才对已登录的会话立即生效；没开屏保的换上空白屏保。
    /// 屏保正在运行时这个调用失败，改为直接写进用户配置，下次登录时生效。
    /// 屏保比熄屏早一分钟启动，锁屏不被熄屏抢先。CONSOLELOCK 管从睡眠唤醒时是否要求登录。
    /// 关锁屏时屏保也关掉：不熄屏时屏保会一直渲染。
    static func windowsScript(locks: Bool) -> String {
        let screen = locks
            ? """
            $desktop = Get-ItemProperty 'HKCU:\\Control Panel\\Desktop'
            if ($desktop.ScreenSaveActive -ne '1' -or -not $desktop.'SCRNSAVE.EXE') {
              Set-ItemProperty 'HKCU:\\Control Panel\\Desktop' 'SCRNSAVE.EXE' "$env:SystemRoot\\System32\\scrnsave.scr"
              Set-Spi 15 \((displaySleepMinutes - 1) * 60)
              Set-Spi 17 1
            }
            Set-Spi 119 1
            $values = [regex]::Matches((powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Out-String), '0x[0-9a-fA-F]{8}')
            if ($values.Count -ge 2 -and [Convert]::ToUInt32($values[$values.Count - 2].Value, 16) -eq 0) {
              powercfg /change monitor-timeout-ac \(displaySleepMinutes)
            }
            """
            : """
            Set-Spi 17 0
            Set-Spi 119 0
            powercfg /change monitor-timeout-ac 0
            """
        return """
        Add-Type -Namespace MacVM -Name Spi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint flags);'
        $spiValues = @{ 15 = 'ScreenSaveTimeOut'; 17 = 'ScreenSaveActive'; 119 = 'ScreenSaverIsSecure' }
        function Set-Spi($action, $param) {
          if (-not [MacVM.Spi]::SystemParametersInfo($action, $param, [IntPtr]::Zero, 3)) {
            Set-ItemProperty 'HKCU:\\Control Panel\\Desktop' $spiValues[$action] "$param"
          }
        }
        \(screen)
        if ($LASTEXITCODE) { throw "powercfg exited with $LASTEXITCODE" }
        foreach ($flag in '/setacvalueindex', '/setdcvalueindex') {
          powercfg $flag SCHEME_CURRENT SUB_NONE CONSOLELOCK \(locks ? 1 : 0)
          if ($LASTEXITCODE) { throw "powercfg exited with $LASTEXITCODE" }
        }
        powercfg /setactive SCHEME_CURRENT
        if ($LASTEXITCODE) { throw "powercfg exited with $LASTEXITCODE" }
        """
    }

    /// 以 root 运行：GNOME 的系统默认设置管之后登录的会话，已登录的会话以会话用户身份接上它的会话总线立即改。
    /// 没有 GNOME（没有 dconf、gsettings）的客户机什么都不做。
    static func linuxScript(locks: Bool) -> String {
        let value = locks ? "true" : "false"
        let idleDelay = locks ? linuxIdleDelaySeconds : 0
        let session = locks
            ? #"[ "$(as_user gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)" = "uint32 0" ] && "# + "as_user gsettings set org.gnome.desktop.session idle-delay \(idleDelay)"
            : "as_user gsettings set org.gnome.desktop.session idle-delay 0"
        return """
        set -u
        if command -v dconf >/dev/null 2>&1; then
          mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
          [ -f /etc/dconf/profile/user ] || printf 'user-db:user\\nsystem-db:local\\n' > /etc/dconf/profile/user
          printf '%s\\n' '[org/gnome/desktop/screensaver]' 'lock-enabled=\(value)' 'ubuntu-lock-on-suspend=\(value)' '' '[org/gnome/desktop/session]' 'idle-delay=uint32 \(idleDelay)' > /etc/dconf/db/local.d/95-macvm-screen-lock
          dconf update || exit 1
        fi
        command -v gsettings >/dev/null 2>&1 || exit 0
        as_user() { runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
        for bus in /run/user/*/bus; do
          [ -S "$bus" ] || continue
          uid=${bus#/run/user/}; uid=${uid%/bus}
          user=$(id -nu "$uid" 2>/dev/null) || continue
          for key in lock-enabled ubuntu-lock-on-suspend; do
            as_user gsettings set org.gnome.desktop.screensaver "$key" \(value) 2>/dev/null || true
          done
          \(session) 2>/dev/null || true
        done
        """
    }
}
