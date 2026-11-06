import Foundation
public import MacVMModel

/// 经 SSH 调整 macOS 客户机里的系统设置，降低空闲时的 CPU、磁盘与内存占用。
///
/// 每项单独执行、单独报告结果，一项失败不影响其余各项；要 root 的项经 `sudo -S` 用客户机密码执行。
public enum MacOSTuning {
    public enum Step: String, CaseIterable, Codable, Sendable {
        /// Spotlight 索引：装完系统后 mds_stores 会长时间占满 CPU 与磁盘。
        case spotlight
        /// 系统睡眠与 Power Nap：客户机睡下后宿主连不上它。
        case sleep
        /// 屏幕保护程序：没人看时仍在客户机里渲染动画。
        case screensaver
        /// 自动检查、下载与安装系统更新：后台下载并准备数 GB 的更新。
        case updates
        /// 窗口与 Dock 动画。
        case animations
        /// 辅助功能里的减少透明度与减少动态效果：毛玻璃每帧都要合成。
        /// 该偏好域受隐私保护，SSH 会话没有完全磁盘访问权限时写不进去。
        case transparency

        var asRoot: Bool {
            switch self {
            case .spotlight, .sleep, .updates: true
            case .screensaver, .animations, .transparency: false
            }
        }

        /// 依次执行，任一条失败即视为该项失败。
        fileprivate var applyCommands: [String] {
            switch self {
            case .spotlight: ["mdutil -a -i off"]
            case .sleep: ["pmset -a sleep 0 disksleep 0 powernap 0"]
            case .screensaver: ["defaults -currentHost write com.apple.screensaver idleTime -int 0"]
            case .updates: Self.softwareUpdateKeys.map { "defaults write \(Self.softwareUpdateDomain) \($0) -bool false" }
            case .animations: Self.animationDefaults.map { "defaults write \($0.domain) \($0.key) \($0.value)" } + [Self.restartDock]
            case .transparency: Self.accessibilityKeys.map { "defaults write com.apple.universalaccess \($0) -bool true" }
            }
        }

        /// 恢复系统默认：删掉写入的键，键本来不存在也算成功。
        fileprivate var revertCommands: [String] {
            switch self {
            case .spotlight: ["mdutil -a -i on"]
            case .sleep: ["pmset restoredefaults"]
            case .screensaver: [Self.delete("com.apple.screensaver", "idleTime", currentHost: true)]
            case .updates: Self.softwareUpdateKeys.map { Self.delete(Self.softwareUpdateDomain, $0) }
            case .animations: Self.animationDefaults.map { Self.delete($0.domain, $0.key) } + [Self.restartDock]
            case .transparency: Self.accessibilityKeys.map { Self.delete("com.apple.universalaccess", $0) }
            }
        }

        private static let softwareUpdateDomain = "/Library/Preferences/com.apple.SoftwareUpdate"
        private static let softwareUpdateKeys = ["AutomaticCheckEnabled", "AutomaticDownload", "AutomaticallyInstallMacOSUpdates"]
        private static let accessibilityKeys = ["reduceTransparency", "reduceMotion"]
        private static let animationDefaults: [(domain: String, key: String, value: String)] = [
            ("-g", "NSAutomaticWindowAnimationsEnabled", "-bool false"),
            ("-g", "NSWindowResizeTime", "-float 0.001"),
            ("com.apple.dock", "launchanim", "-bool false"),
            ("com.apple.dock", "expose-animation-duration", "-float 0.1"),
        ]
        /// Dock 重启后才读新设置；没有图形会话时 Dock 不在，不算失败。
        private static let restartDock = "{ killall Dock || true; }"

        private static func delete(_ domain: String, _ key: String, currentHost: Bool = false) -> String {
            "{ defaults \(currentHost ? "-currentHost " : "")delete \(domain) \(key) || true; }"
        }
    }

    public struct Report: Codable, Sendable, Equatable {
        public var applied: [Step]
        public var failed: [Step]
        /// 为 true 时 `applied` 是已恢复默认的项。
        public var reverted: Bool
    }

    /// 在运行中且 SSH 可用的客户机里执行 `steps`。只有用户级的项时不需要密码；
    /// `password` 为 nil 时用包内保存的客户机密码。sudo 认证失败时抛错，此前用户级的项可能已生效。
    public static func run(bundle: VMBundle, config: VMConfig, steps: [Step] = Step.allCases, revert: Bool = false,
                           password: String? = nil, macvmPath: String) async throws -> Report {
        guard config.os == .macOS else { throw MacVMError.unsupported(String(l10n: "Only macOS guests can be tuned")) }
        guard let user = config.guestUser else { throw MacVMError.unsupported(String(l10n: "\(config.name)'s login user is unknown, so it can't be tuned over SSH")) }
        let userSteps = steps.filter { !$0.asRoot }, rootSteps = steps.filter(\.asRoot)

        var remote: [String] = []
        if !userSteps.isEmpty { remote.append(decodedShell(script(userSteps, revert: revert))) }
        var stdin: URL?
        if !rootSteps.isEmpty {
            guard let password = password ?? GuestCredentials.password(for: bundle) else {
                throw MacVMError.invalidConfig(String(l10n: "No guest password is saved for \(config.name), so sudo isn't available; provide one with --password"))
            }
            let file = FileManager.default.temporaryDirectory.appending(path: "macvm-sudo-\(UUID().uuidString)")
            try GuestCredentials.writePrivate(Data((password + "\n").utf8), to: file)
            stdin = file
            // 放在最后：整条命令的退出码就是 sudo 的，认证失败才会被当作出错。
            remote.append("sudo -S -p '' " + decodedShell(script(rootSteps, revert: revert)))
        }
        defer { if let stdin { try? FileManager.default.removeItem(at: stdin) } }
        guard !remote.isEmpty else { return Report(applied: [], failed: [], reverted: revert) }

        let ssh = AgentInstaller.sshArguments(bundle: bundle, user: user, macvmPath: macvmPath)
        let output = try await Subprocess.run("/usr/bin/ssh", ssh + [remote.joined(separator: "; ")], stdin: stdin)
        return parse(output, steps: steps, revert: revert)
    }

    /// 每项输出一行 `ok <项>` 或 `fail <项>`。
    static func script(_ steps: [Step], revert: Bool) -> String {
        let lines = steps.map { step in
            let commands = (revert ? step.revertCommands : step.applyCommands).joined(separator: " && ")
            return "if { \(commands); } >/dev/null 2>&1; then echo 'ok \(step.rawValue)'; else echo 'fail \(step.rawValue)'; fi"
        }
        return (lines + ["exit 0"]).joined(separator: "\n")
    }

    /// 客户机登录 shell 先解码再交给 /bin/sh，脚本里的引号不必再经一层 shell 转义。
    private static func decodedShell(_ script: String) -> String {
        "/bin/sh -c \"$(printf %s \(Data(script.utf8).base64EncodedString()) | base64 -D)\""
    }

    /// 没有输出结果行的项算失败。
    static func parse(_ output: String, steps: [Step], revert: Bool) -> Report {
        var ok = Set<Step>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == "ok", let step = Step(rawValue: String(parts[1])) { ok.insert(step) }
        }
        return Report(applied: steps.filter(ok.contains), failed: steps.filter { !ok.contains($0) }, reverted: revert)
    }
}
