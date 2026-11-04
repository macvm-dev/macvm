public import Foundation

/// 存放所有虚拟机包的目录。
public struct VMLibrary: Sendable {
    public let root: URL

    /// 依次取环境变量 `MACVM_HOME`、`MacVMSettings.libraryPath`、`defaultRoot`。
    public static var `default`: VMLibrary {
        VMLibrary(root: environmentRoot ?? MacVMSettings.directory(MacVMSettings.load().libraryPath) ?? defaultRoot)
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVM/VMs", directoryHint: .isDirectory)
    }

    /// 设置了 `MACVM_HOME` 时的目录；它优先于设置文件。
    public static var environmentRoot: URL? {
        MacVMSettings.directory(ProcessInfo.processInfo.environment["MACVM_HOME"])
    }

    public init(root: URL) { self.root = root }

    /// 名称同时用作目录名和 socket 文件名，限制字符集与长度以保证两者都合法。
    public static func validate(name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...40).contains(name.count),
              name.unicodeScalars.allSatisfy(allowed.contains),
              !name.hasPrefix("."), !name.hasPrefix("-")
        else {
            throw MacVMError.invalidConfig("名称须为 1–40 个字母、数字或 . _ -，且不以 . 或 - 开头：\(name)")
        }
    }

    public func bundleURL(named name: String) -> URL {
        root.appending(path: "\(name).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
    }

    public func bundle(named name: String) throws -> VMBundle {
        try Self.validate(name: name)
        let url = bundleURL(named: name)
        guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path) else {
            throw MacVMError.vmNotFound(name)
        }
        return VMBundle(url: url)
    }

    public func all() throws -> [VMBundle] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return items
            .filter { $0.pathExtension == VMBundle.pathExtension }
            .map(VMBundle.init(url:))
            .filter { FileManager.default.fileExists(atPath: $0.configURL.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
