public import Foundation

extension Bundle {
    /// 界面文案（`Localizable.strings`）所在的 bundle。
    ///
    /// App 及其 `Contents/MacOS` 下的进程直接用主 bundle。`macvm` 在 App 包的 `Contents/Resources/bin` 下，
    /// 主 bundle 不是 App 包；从 App 包里取文案时 Foundation 只按主 bundle 已有的语言选，CLI 的主 bundle 没有语言，
    /// 总会落到开发语言，所以这里自己挑出 App 包里的 `.lproj` 用。挑语言时先看 App 偏好域里的 `AppleLanguages`
    /// （给 MacVM 单独设的语言存在那里，CLI 自己的偏好域读不到），没有再按系统首选语言，与 App 进程保持同一种语言。
    /// 不在 App 包的 `Contents/Resources/bin` 下（开发构建）时用主 bundle，文案即源码里的英文。
    public static let macvm: Bundle = {
        let main = Bundle.main
        if main.bundleURL.pathExtension == "app" { return main }
        guard let exe = main.executableURL?.resolvingSymlinksInPath() else { return main }
        let bin = exe.deletingLastPathComponent()
        let dir = bin.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard dir.pathExtension == "app", let app = Bundle(url: dir), let resources = app.resourceURL,
              resources.appending(path: "bin").resolvingSymlinksInPath().path == bin.path else { return main }
        let preferences = app.bundleIdentifier.flatMap { UserDefaults(suiteName: $0)?.stringArray(forKey: "AppleLanguages") }
        let language = Bundle.preferredLocalizations(from: app.localizations, forPreferences: preferences ?? Locale.preferredLanguages).first
        guard let language, let lproj = Bundle(url: resources.appending(path: "\(language).lproj")) else { return app }
        return lproj
    }()
}

extension String {
    /// 按用户首选语言取界面文案。`value` 是英文原文，也是查表的键，没有译文时原样显示。
    /// 参数类型是 `String.LocalizationValue`，编译器据此把调用处的字面量抽进字符串表。
    public init(l10n value: String.LocalizationValue) {
        self.init(localized: value, bundle: .macvm)
    }
}

extension Sequence<String> {
    /// 并列列举给人看的名称：英文 "a, b"，中文「a、b」，分隔符随 `Bundle.macvm` 选中的语言。
    public func joinedAsList() -> String {
        joined(separator: String(l10n: ", "))
    }
}
