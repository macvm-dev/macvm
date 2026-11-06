public import Foundation
public import MacVMModel

/// 定位随程序分发的客户机代理，并把它装进客户机。
public enum AgentInstaller {
    public static let linuxPath = "/usr/local/bin/macvm-agent"
    /// Windows 上放代理、令牌与显卡驱动的目录。
    static let windowsDirectory = #"C:\ProgramData\macvm"#
    static let windowsPath = windowsDirectory + #"\macvm-agent.exe"#
    static let windowsTaskName = "macvm-agent"
    /// 开机时以 SYSTEM 运行安全桌面守护进程的计划任务。
    static let windowsDesktopTaskName = "macvm-agent-desktop"
    /// macOS 版代理 App 包的 bundle ID，也是 LaunchAgent 的标签。
    static let launchAgentLabel = "cn.barey.macvm.agent"
    static let macOSAppName = "MacVM Agent.app"
    /// 代理 App 包在客户机用户主目录下的位置：不放进「应用程序」，免得用户当成普通 App 打开。
    static let macOSAppDirectory = "Library/Application Support/macvm"
    /// macOS 客户机首次开机时 SSH 先于图形登录就绪，登录会话建好前 `launchctl bootstrap gui/<uid>` 会失败；
    /// 安装脚本最多等这么多秒。登录过程会自行加载 `~/Library/LaunchAgents` 里的代理，加载上了也算装好。
    static let macOSLoginWait = 120

    public static func binary(for os: GuestOS) -> URL? {
        switch os {
        case .linux: GuestFiles.locate("macvm-agent-linux")
        case .macOS: GuestFiles.locate(macOSAppName)
        case .windows: GuestFiles.locate("macvm-agent-windows.exe")
        }
    }

    /// 种子盘装代理用：systemd 单元，与 cloud-init 从种子盘安装代理的命令。
    /// 显卡 udev 规则要赶在 GNOME 挑显卡之前生效：由 `ExecStartPre` 同步写好，单元排在显示管理器之前，
    /// 显示管理器要等它写完才启动；写失败不挡代理启动。
    static func linuxCloudInit(user: String) -> (unit: String, install: String) {
        let unit = """
        [Unit]
        Description=macvm guest agent
        After=local-fs.target
        Before=display-manager.service

        [Service]
        ExecStartPre=-\(linuxPath) --ignore-firmware-framebuffer
        ExecStart=\(linuxPath) --user \(user)
        Restart=always
        RestartSec=1

        [Install]
        WantedBy=multi-user.target

        """
        let install = "mkdir -p /run/macvm-seed && mount -o ro /dev/disk/by-label/cidata /run/macvm-seed && install -m 0755 /run/macvm-seed/macvm-agent \(linuxPath); umount /run/macvm-seed; systemctl daemon-reload; systemctl enable --now macvm-agent"
        return (unit, install)
    }

    /// 停下代理并备好 `windowsDirectory` 的 PowerShell 片段，往这个目录里放任何东西之前运行。
    /// 普通用户能在 ProgramData 下建目录，抢先建好它就能换掉以最高权限运行的代理或读到令牌：
    /// 目录或其中任何一项不归 SYSTEM、Administrators 或当前（管理员）用户所有、或是重解析点时，整个挪开重建。
    /// 之后目录归 Administrators，权限不继承，只给 SYSTEM 与 Administrators；新建时即带这份权限。
    /// 收紧权限后再查一遍，仍不可信就抛错中止，不往里写。片段只用 ASCII：Windows PowerShell 按 ANSI 读无 BOM 的脚本。
    static var windowsPrepareDirectory: String {
        """
        Stop-ScheduledTask -TaskName \(windowsDesktopTaskName) -ErrorAction SilentlyContinue
        Stop-ScheduledTask -TaskName \(windowsTaskName) -ErrorAction SilentlyContinue
        Get-Process macvm-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        $macvm = \(PowerShell.quote(windowsDirectory))
        $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
        $trusted = @('S-1-5-18', $admins.Value, [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        function Test-MacVMOwner($item, $owners) {
          try { $item.GetAccessControl('Owner').GetOwner([Security.Principal.SecurityIdentifier]).Value -in $owners } catch { $false }
        }
        function Test-MacVMTrusted($root) {
          $queue = New-Object Collections.Queue
          $queue.Enqueue($root)
          try {
            while ($queue.Count) {
              $item = $queue.Dequeue()
              if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-MacVMOwner $item $trusted)) { return $false }
              if ($item -is [IO.DirectoryInfo]) { foreach ($child in $item.GetFileSystemInfos()) { $queue.Enqueue($child) } }
            }
            return $true
          } catch { return $false }
        }
        $top = Get-ChildItem -LiteralPath (Split-Path $macvm) -Force -Filter (Split-Path $macvm -Leaf) -ErrorAction Stop
        if ($top -and -not (Test-MacVMTrusted $top)) {
          Rename-Item -LiteralPath $macvm -NewName "macvm.untrusted-$([guid]::NewGuid())" -ErrorAction Stop
          $top = $null
        }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($admins)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($owner in 'S-1-5-18', $admins.Value) {
          $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $owner), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        }
        if ($top) { $top.SetAccessControl($acl) } else { [void][IO.Directory]::CreateDirectory($macvm, $acl) }
        $dir = Get-Item -LiteralPath $macvm -Force -ErrorAction Stop
        if (-not ($dir -is [IO.DirectoryInfo]) -or -not (Test-MacVMOwner $dir @($admins.Value)) -or -not (Test-MacVMTrusted $dir)) {
          throw "$macvm has an untrusted owner or content; not installing macvm-agent"
        }
        """
    }

    /// Windows 上把 `source` 处的代理装好并启动的 PowerShell 片段，要在 `windowsPrepareDirectory` 之后运行：
    /// 登录时以最高权限在 `user` 的交互会话里运行的计划任务（剪贴板只在交互会话可用），
    /// 开机时以 SYSTEM 运行的安全桌面守护任务（UAC 提示与锁屏上的 UI 自动化），外加对所有网络生效的入站规则。
    static func windowsRegistration(source: String, user: String) -> String {
        let quoted = PowerShell.quote
        return """
        $exe = \(quoted(windowsPath))
        Copy-Item -LiteralPath \(source) -Destination $exe -Force
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId \(quoted(user)) -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName \(windowsTaskName) -Action (New-ScheduledTaskAction -Execute $exe) -Trigger (New-ScheduledTaskTrigger -AtLogOn -User \(quoted(user))) -Principal $principal -Settings $settings -Force | Out-Null
        $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName \(windowsDesktopTaskName) -Action (New-ScheduledTaskAction -Execute $exe -Argument '--desktop-supervisor') -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $system -Settings $settings -Force | Out-Null
        Remove-NetFirewallRule -Name \(windowsTaskName) -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name \(windowsTaskName) -DisplayName 'macvm agent' -Profile Any -Direction Inbound -Protocol TCP -LocalPort \(AgentProtocol.port) -Program $exe -Action Allow | Out-Null
        Start-ScheduledTask -TaskName \(windowsDesktopTaskName)
        Start-ScheduledTask -TaskName \(windowsTaskName)
        """
    }

    /// 经 SSH 安装到已运行的客户机：Linux 装为 systemd 服务（root），macOS 装为登录会话里的 LaunchAgent，
    /// Windows 装为登录时运行的计划任务；后两者在交互会话里运行，才能访问剪贴板。
    /// macOS 的 LaunchAgent 关联代理 App 包，客户机「登录项」里显示为包名而不是签名的开发者名。
    /// 用 qemu 引擎的 Windows 在自带 QEMU 带 3D 时一并放进 viogpu3d 驱动包，返回是否放了。
    @discardableResult
    public static func installOverSSH(bundle: VMBundle, config: VMConfig, macvmPath: String) async throws -> Bool {
        guard let user = config.guestUser else { throw MacVMError.unsupported("不知道 \(config.name) 的登录用户，无法经 SSH 安装代理") }
        guard let binary = binary(for: config.os) else { throw MacVMError.io("找不到 \(config.os.rawValue) 版客户机代理，先运行 make agent") }
        try SSHConfig.validateLogin(user: user, host: bundle.name)
        let ssh = sshArguments(bundle: bundle, user: user, macvmPath: macvmPath)
        // 宿主包里一有令牌就对代理要求质询：新生成的令牌在送进客户机之前就失败时删掉，现有代理才连得上。
        var tokenDelivered = config.os == .macOS || AgentToken.read(bundle) != nil
        let token = config.os == .macOS ? nil : try AgentToken.ensure(bundle)
        defer { if !tokenDelivered { try? FileManager.default.removeItem(at: AgentToken.url(bundle)) } }

        let script: String
        switch config.os {
        case .linux:
            script = """
            set -e
            sudo sh -c 'cat > \(linuxPath).new && chmod 0755 \(linuxPath).new && mv -f \(linuxPath).new \(linuxPath)'
            sudo tee /etc/systemd/system/macvm-agent.service >/dev/null <<'UNIT'
            \(linuxCloudInit(user: user).unit)UNIT
            sudo systemctl daemon-reload
            sudo systemctl enable macvm-agent >/dev/null 2>&1
            sudo systemctl restart macvm-agent
            """
        case .macOS:
            script = macOSInstallScript(user: user, detachOutput: false)
        case .windows:
            // Windows 的 sshd 把命令交给 PowerShell 执行，经标准输入传二进制不可靠，改用 scp 传到用户目录。
            let staged = "macvm-agent.exe"
            let scp = ["-q"] + ssh.dropLast().filter { $0 != "-T" }
            try await Subprocess.run("/usr/bin/scp", scp + [binary.path, "\(ssh.last!):\(staged)"])
            var install = windowsPrepareDirectory + "\n"
            let gpuDriver = config.engine == .qemu ? WindowsGPUDriver.package(QEMUInstallation.locate()) : nil
            if let gpuDriver {
                // 先放驱动包再重启代理，代理启动时即可装上。
                let local = FileManager.default.temporaryDirectory.appending(path: "macvm-\(WindowsUnattend.gpuDriverFolder)-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: local) }
                try await WindowsGPUDriver.extract(gpuDriver, to: local)
                try await Subprocess.run("/usr/bin/scp", scp + ["-r", local.path, "\(ssh.last!):\(WindowsUnattend.gpuDriverFolder)"])
                let target = "'\(WindowsGPUDriver.guestDirectory)'"
                install += """
                Remove-Item -Recurse -Force -LiteralPath \(target) -ErrorAction SilentlyContinue
                Move-Item -LiteralPath (Join-Path $HOME '\(WindowsUnattend.gpuDriverFolder)') -Destination \(target)

                """
            }
            install += AgentToken.windowsInstall(token!) + "\n"
            install += windowsRegistration(source: "(Join-Path $HOME '\(staged)')", user: user) + "\nRemove-Item (Join-Path $HOME '\(staged)')"
            // 脚本中途失败时不知道令牌是否已写进客户机，保留宿主这份。
            tokenDelivered = true
            try await Subprocess.run("/usr/bin/ssh", ssh + [encodedPowerShell(install)])
            return gpuDriver != nil
        }
        if config.os == .linux {
            // 令牌经标准输入传，不进客户机的命令行。
            try await Subprocess.run("/usr/bin/ssh", ssh + ["sudo sh -c '\(AgentToken.linuxInstallCommand())'"], stdin: AgentToken.url(bundle))
            tokenDelivered = true
        }
        if config.os == .macOS {
            let archive = try await macOSArchive(binary)
            defer { try? FileManager.default.removeItem(at: archive) }
            try await Subprocess.run("/usr/bin/ssh", ssh + [script], stdin: archive)
            return false
        }
        try await Subprocess.run("/usr/bin/ssh", ssh + [script], stdin: binary)
        return false
    }

    /// `installOverSSH` 之后等代理上线，上线了才把 `guestAgent` 写回配置，再按 `VMConfig.screenLock` 设好锁屏（失败不算）；放了显卡驱动包时同时写 `graphicsAcceleration`，
    /// 客户机里有了这个驱动就只能用带 3D 的 QEMU 运行。写回前重读配置：安装期间配置可能被别处改过。
    public static func installAndEnable(bundle: VMBundle, config: VMConfig, macvmPath: String) async throws -> (online: Bool, gpuDriver: Bool) {
        let gpuDriver = try await installOverSSH(bundle: bundle, config: config, macvmPath: macvmPath)
        guard try await VMStatus.poll(timeout: 30, interval: 0.3, { AgentClient.isReachable(bundle) }) else { return (false, gpuDriver) }
        var config = try bundle.loadConfig()
        config.guestAgent = true
        if gpuDriver { config.graphicsAcceleration = true }
        try bundle.saveConfig(config)
        try? GuestScreenLock.apply(bundle, config: config)
        return (true, gpuDriver)
    }

    /// 以登录用户运行、标准输入是代理 App 包 tar 的安装脚本：换掉包，写 LaunchAgent，重新加载它。
    /// 由旧代理执行时，重新加载会结束代理与本脚本的输出管道，`detachOutput` 让脚本此前把输出改到 /dev/null，免得写输出时被 SIGPIPE 结束。
    static func macOSInstallScript(user: String, detachOutput: Bool) -> String {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(launchAgentLabel)</string>
        <key>ProgramArguments</key><array><string>/Users/\(user)/\(macOSAppDirectory)/\(macOSAppName)/Contents/MacOS/macvm-agent</string></array>
        <key>AssociatedBundleIdentifiers</key><array><string>\(launchAgentLabel)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
        return """
        set -e
        dir="$HOME/\(macOSAppDirectory)"
        mkdir -p "$dir" ~/Library/LaunchAgents
        staging=$(mktemp -d "$dir/.install.XXXXXX")
        trap 'rm -rf "$staging"' EXIT
        tar -x -f - -C "$staging"
        rm -rf "$dir/\(macOSAppName)"
        mv "$staging/\(macOSAppName)" "$dir/"
        rm -f ~/.local/bin/macvm-agent
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dir/\(macOSAppName)"
        cat > ~/Library/LaunchAgents/\(launchAgentLabel).plist <<'PLIST'
        \(plist)
        PLIST
        \(detachOutput ? "exec >/dev/null 2>&1" : "")
        launchctl bootout gui/$(id -u)/\(launchAgentLabel) 2>/dev/null || true
        deadline=$(( $(date +%s) + \(macOSLoginWait) ))
        until launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(launchAgentLabel).plist 2>/dev/null; do
          launchctl print gui/$(id -u)/\(launchAgentLabel) >/dev/null 2>&1 && break
          if [ $(date +%s) -ge $deadline ]; then
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(launchAgentLabel).plist
            exit 1
          fi
          sleep 2
        done
        """
    }

    /// 把代理 App 包 `app` 打成临时目录里的 tar，经标准输入传进客户机；用完由调用方删除。
    /// 不带 AppleDouble 等扩展属性文件，免得混进包里破坏签名。
    static func macOSArchive(_ app: URL) async throws -> URL {
        let archive = FileManager.default.temporaryDirectory.appending(path: "macvm-agent-\(UUID().uuidString).tar")
        try await Subprocess.run("/usr/bin/tar", ["--no-mac-metadata", "-c", "-f", archive.path,
                                                  "-C", app.deletingLastPathComponent().path, app.lastPathComponent])
        return archive
    }

    /// 多行脚本经 sshd 交给 PowerShell 时会按行拆开，编码成一条 `-EncodedCommand`（UTF-16LE 的 Base64）。
    static func encodedPowerShell(_ script: String) -> String {
        "powershell -NoProfile -NonInteractive -EncodedCommand \(powerShellBase64(script))"
    }

    /// `-EncodedCommand` 的参数：脚本的 UTF-16LE 编码再 Base64。
    static func powerShellBase64(_ script: String) -> String {
        var bytes = Data()
        for unit in script.utf16 { bytes.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        return bytes.base64EncodedString()
    }

    static func sshArguments(bundle: VMBundle, user: String, macvmPath: String) -> [String] {
        let proxy = SSHConfig.proxyCommand(macvmPath: macvmPath, name: bundle.name, flags: ["--tcp"])
        return ["-q", "-T"] + SSHConfig.keyArguments(proxyCommand: proxy) + ["\(user)@\(bundle.name)"]
    }
}
