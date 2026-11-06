import AppKit
import Foundation

/// 界面语言：存在 App 偏好域的 `AppleLanguages` 里，与「系统设置 › 通用 › 语言与地区」给单个 App 设的语言是同一项。
/// Foundation 在进程启动时选定语言，改了要重启 App 才生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: Self { self }

    private static let key = "AppleLanguages"

    /// 语言名用它自己的文字写，不随界面语言翻译：看不懂当前界面的人也认得出。
    var name: String {
        guard self != .system else { return String(l10n: "System Default") }
        return Locale(identifier: rawValue).localizedString(forIdentifier: rawValue) ?? rawValue
    }

    /// 给 MacVM 单独设的语言；只看 App 自己的偏好域，`UserDefaults.standard` 会把全局域的系统语言也读进来。
    static var current: AppLanguage {
        guard let first = appDomainLanguages?.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    static func set(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// 本进程启动时选定、界面正在用的 `.lproj`。
    static let active = Bundle.main.preferredLocalizations.first

    /// 按 `current` 下次启动会用的 `.lproj`。
    static var next: String? {
        let preferences = current == .system ? systemLanguages : [current.rawValue]
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
    }

    private static var appDomainLanguages: [String]? {
        Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?[key] as? [String] }
    }

    private static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? Locale.preferredLanguages
    }

    // MARK: 重启

    /// 本次退出后要重新打开 App；退出被取消时要清掉，否则之后的普通退出也会重开。
    @MainActor static var restartRequested = false

    /// 走正常的退出流程（运行中的虚拟机照常询问转到后台、挂起或关机），退出后再打开本 App。
    @MainActor static func restart() {
        restartRequested = true
        NSApp.terminate(nil)
    }

    /// 在 App 退出时调用：起一个子进程等本进程退出后再打开 App 包。单实例锁随进程释放，不能在退出前打开。
    @MainActor static func reopenAfterExit() {
        guard restartRequested else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? process.run()
    }
}
