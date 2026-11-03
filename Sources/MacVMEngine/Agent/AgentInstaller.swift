public import Foundation
public import MacVMModel

/// 定位随程序分发的客户机代理，并把它装进客户机。
public enum AgentInstaller {
    public static let linuxPath = "/usr/local/bin/macvm-agent"
    static let windowsPath = #"C:\ProgramData\macvm\macvm-agent.exe"#
    static let windowsTaskName = "macvm-agent"
    static let launchAgentLabel = "cn.barey.macvm.agent"

    public static func binary(for os: GuestOS) -> URL? {
        switch os {
        case .linux: GuestFiles.locate("macvm-agent-linux")
        case .macOS: GuestFiles.locate("macvm-agent-darwin")
        case .windows: GuestFiles.locate("macvm-agent-windows.exe")
        }
    }

    /// cloud-init 用：systemd 单元与从种子盘安装代理的命令。
    static func linuxCloudInit(user: String) -> (unit: String, install: String) {
        let unit = """
        [Unit]
        Description=macvm guest agent
        After=local-fs.target

        [Service]
        ExecStart=\(linuxPath) --user \(user)
        Restart=always
        RestartSec=1

        [Install]
        WantedBy=multi-user.target

        """
        let install = "mkdir -p /run/macvm-seed && mount -o ro /dev/disk/by-label/cidata /run/macvm-seed && install -m 0755 /run/macvm-seed/macvm-agent \(linuxPath); umount /run/macvm-seed; systemctl daemon-reload; systemctl enable --now macvm-agent"
        return (unit, install)
    }

    /// Windows 上把 `source` 处的代理装好并启动的 PowerShell 片段：
    /// 登录时以最高权限在 `user` 的交互会话里运行的计划任务（剪贴板只在交互会话可用），
    /// 外加对所有网络生效的入站规则。代理自己只接受来自默认网关（宿主）的连接。
    static func windowsRegistration(source: String, user: String) -> String {
        let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return """
        $exe = \(quoted(windowsPath))
        Stop-ScheduledTask -TaskName \(windowsTaskName) -ErrorAction SilentlyContinue
        Get-Process macvm-agent -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 500
        New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
        Copy-Item -LiteralPath \(source) -Destination $exe -Force
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId \(quoted(user)) -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName \(windowsTaskName) -Action (New-ScheduledTaskAction -Execute $exe) -Trigger (New-ScheduledTaskTrigger -AtLogOn -User \(quoted(user))) -Principal $principal -Settings $settings -Force | Out-Null
        Remove-NetFirewallRule -Name \(windowsTaskName) -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name \(windowsTaskName) -DisplayName 'macvm agent' -Profile Any -Direction Inbound -Protocol TCP -LocalPort \(AgentProtocol.port) -Program $exe -Action Allow | Out-Null
        Start-ScheduledTask -TaskName \(windowsTaskName)
        """
    }

    /// 经 SSH 安装到已运行的客户机：Linux 装为 systemd 服务（root），macOS 装为登录会话里的 LaunchAgent，
    /// Windows 装为登录时运行的计划任务；后两者在交互会话里运行，才能访问剪贴板。
    /// 用 qemu 引擎的 Windows 在自带 QEMU 带 3D 时一并放进 viogpu3d 驱动包，返回是否放了。
    @discardableResult
    public static func installOverSSH(bundle: VMBundle, config: VMConfig, macvmPath: String) async throws -> Bool {
        guard let user = config.guestUser else { throw MacVMError.unsupported("不知道 \(config.name) 的登录用户，无法经 SSH 安装代理") }
        guard let binary = binary(for: config.os) else { throw MacVMError.io("找不到 \(config.os.rawValue) 版客户机代理，先运行 make agent") }
        let ssh = sshArguments(bundle: bundle, user: user, macvmPath: macvmPath)

        let script: String
        switch config.os {
        case .linux:
            script = """
            set -e
            sudo install -m 0755 /dev/stdin \(linuxPath)
            sudo tee /etc/systemd/system/macvm-agent.service >/dev/null <<'UNIT'
            \(linuxCloudInit(user: user).unit)UNIT
            sudo systemctl daemon-reload
            sudo systemctl enable macvm-agent >/dev/null 2>&1
            sudo systemctl restart macvm-agent
            """
        case .macOS:
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key><array><string>/Users/\(user)/.local/bin/macvm-agent</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Interactive</string>
            </dict></plist>
            """
            script = """
            set -e
            mkdir -p ~/.local/bin ~/Library/LaunchAgents
            cat > ~/.local/bin/macvm-agent.new && chmod 0755 ~/.local/bin/macvm-agent.new && mv ~/.local/bin/macvm-agent.new ~/.local/bin/macvm-agent
            cat > ~/Library/LaunchAgents/\(launchAgentLabel).plist <<'PLIST'
            \(plist)
            PLIST
            launchctl bootout gui/$(id -u)/\(launchAgentLabel) 2>/dev/null || true
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(launchAgentLabel).plist
            """
        case .windows:
            // Windows 的 sshd 把命令交给 PowerShell 执行，经标准输入传二进制不可靠，改用 scp 传到用户目录。
            let staged = "macvm-agent.exe"
            let scp = ["-q"] + ssh.dropLast().filter { $0 != "-T" }
            try await Subprocess.run("/usr/bin/scp", scp + [binary.path, "\(ssh.last!):\(staged)"])
            var install = ""
            let gpuDriver = config.engine == .qemu ? WindowsGPUDriver.package(QEMUInstallation.locate()) : nil
            if let gpuDriver {
                // 先放驱动包再重启代理，代理启动时即可装上。
                let local = FileManager.default.temporaryDirectory.appending(path: "macvm-\(WindowsUnattend.gpuDriverFolder)-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: local) }
                try await WindowsGPUDriver.extract(gpuDriver, to: local)
                try await Subprocess.run("/usr/bin/scp", scp + ["-r", local.path, "\(ssh.last!):\(WindowsUnattend.gpuDriverFolder)"])
                let target = "'\(WindowsGPUDriver.guestDirectory)'"
                install += """
                New-Item -ItemType Directory -Force -Path (Split-Path \(target)) | Out-Null
                Remove-Item -Recurse -Force -LiteralPath \(target) -ErrorAction SilentlyContinue
                Move-Item -LiteralPath (Join-Path $HOME '\(WindowsUnattend.gpuDriverFolder)') -Destination \(target)

                """
            }
            install += windowsRegistration(source: "(Join-Path $HOME '\(staged)')", user: user) + "\nRemove-Item (Join-Path $HOME '\(staged)')"
            try await Subprocess.run("/usr/bin/ssh", ssh + [encodedPowerShell(install)])
            return gpuDriver != nil
        }
        try await Subprocess.run("/usr/bin/ssh", ssh + [script], stdin: binary)
        return false
    }

    /// 多行脚本经 sshd 交给 PowerShell 时会按行拆开，编码成一条 `-EncodedCommand`（UTF-16LE 的 Base64）。
    static func encodedPowerShell(_ script: String) -> String {
        var bytes = Data()
        for unit in script.utf16 { bytes.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        return "powershell -NoProfile -NonInteractive -EncodedCommand \(bytes.base64EncodedString())"
    }

    static func sshArguments(bundle: VMBundle, user: String, macvmPath: String) -> [String] {
        ["-q", "-T", "-i", SSHKeys.privateKeyURL.path, "-o", "IdentitiesOnly=yes",
         "-o", "ProxyCommand=\"\(macvmPath)\" proxy \(bundle.name) --tcp",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         "\(user)@\(SSHConfig.hostAlias(for: bundle.name))"]
    }
}
