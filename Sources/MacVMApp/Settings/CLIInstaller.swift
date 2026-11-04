import Foundation

/// App 内置 CLI 的位置；未打包运行（开发构建）时取同目录下的 macvm。
enum CLILocation {
    /// App 包内 CLI 相对包根目录的路径。
    static let bundledPath = "Contents/Resources/bin/macvm"

    static var path: String {
        let bundled = Bundle.main.bundleURL.appending(path: bundledPath)
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "macvm").path
    }
}

/// 让终端里能直接用 `macvm`：在 `~/.local/bin` 放一个指向 App 自带 CLI 的符号链接，不需要管理员权限。
/// 只认 App 包里的 CLI；`/usr/local/bin/macvm` 已指向本 App 时不重复放。
/// 链接的位置上已有别的东西（用户自己的文件、指向别处的链接）时不动它。
enum CLIInstaller {
    private static let linkURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/macvm")
    private static let systemLink = "/usr/local/bin/macvm"
    /// App 包内 CLI 路径的结尾；指向任一份 MacVM.app 的链接都由本 App 接管。
    private static let bundledSuffix = ".app/" + CLILocation.bundledPath

    /// 出错时静默放弃：装不上不影响 App 本身。
    static func installIfNeeded() {
        let bundle = Bundle.main.bundleURL
        // 从 DMG 里直接打开或被系统随机挪位（App Translocation）时，App 在只读卷上，路径用完就失效，链过去只会留下断链。
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return }
        let cli = bundle.appending(path: CLILocation.bundledPath).path
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: cli) else { return }
        if resolved(systemLink) == cli { return }

        let link = linkURL.path
        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            guard target != cli else { return }
            guard target.hasSuffix(bundledSuffix) || !fm.fileExists(atPath: link) else { return }
            try? fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            return
        }
        try? fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: cli)
    }

    private static func resolved(_ path: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        return URL(filePath: target, relativeTo: URL(filePath: path).deletingLastPathComponent()).standardizedFileURL.path
    }
}
