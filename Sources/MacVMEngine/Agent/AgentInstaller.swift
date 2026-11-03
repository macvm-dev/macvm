public import Foundation
public import MacVMModel

/// 定位随程序分发的客户机代理，并把它装进客户机。
public enum AgentInstaller {
    public static let linuxPath = "/usr/local/bin/macvm-agent"
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

    /// 经 SSH 安装到已运行的客户机：Linux 装为 systemd 服务（root），macOS 装为登录会话里的 LaunchAgent，
    /// 后者才能访问剪贴板。
    public static func installOverSSH(bundle: VMBundle, config: VMConfig, macvmPath: String) async throws {
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
            throw MacVMError.unsupported("Windows 客户机的代理由安装流程写入")
        }
        try await Subprocess.run("/usr/bin/ssh", ssh + [script], stdin: binary)
    }

    static func sshArguments(bundle: VMBundle, user: String, macvmPath: String) -> [String] {
        ["-q", "-T", "-i", SSHKeys.privateKeyURL.path, "-o", "IdentitiesOnly=yes",
         "-o", "ProxyCommand=\"\(macvmPath)\" proxy \(bundle.name) --tcp",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         "\(user)@\(SSHConfig.hostAlias(for: bundle.name))"]
    }
}
