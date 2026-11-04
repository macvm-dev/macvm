public import Foundation

/// 本机用户级设置，App 与 CLI 共用，存在 `fileURL`。
/// 字段为 nil 表示用默认值；文件缺失或损坏时全部按默认处理。
public struct MacVMSettings: Codable, Sendable, Equatable {
    /// 虚拟机目录；环境变量 `MACVM_HOME` 优先于它。
    public var libraryPath: String?
    /// 下载缓存目录。
    public var downloadPath: String?
    /// 模板目录。
    public var templatePath: String?

    public init(libraryPath: String? = nil, downloadPath: String? = nil, templatePath: String? = nil) {
        self.libraryPath = libraryPath
        self.downloadPath = downloadPath
        self.templatePath = templatePath
    }

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVM/settings.json")
    }

    public static func load() -> MacVMSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return MacVMSettings() }
        return (try? JSONDecoder().decode(MacVMSettings.self, from: data)) ?? MacVMSettings()
    }

    public func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// 本设置下实际生效的下载缓存目录。
    public var downloadRoot: URL { Self.directory(downloadPath) ?? DownloadCache.defaultRoot }

    /// 本设置下实际生效的模板目录。
    public var templateRoot: URL { Self.directory(templatePath) ?? TemplateLibrary.defaultRoot }

    static func directory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
}

/// 下载缓存目录，未设置时为 `defaultRoot`。
public enum DownloadCache {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVM", directoryHint: .isDirectory)
    }

    public static var root: URL {
        MacVMSettings.load().downloadRoot
    }
}
