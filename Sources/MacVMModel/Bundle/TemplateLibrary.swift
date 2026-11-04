public import Foundation

/// 存放模板的目录。模板是一台已停止虚拟机的副本，包格式与虚拟机相同，只用来新建虚拟机，本身不运行。
public struct TemplateLibrary: Sendable {
    /// 以虚拟机库的形式访问模板目录，供建包、列举复用。
    public let storage: VMLibrary

    public var root: URL { storage.root }

    /// 取 `MacVMSettings.templatePath`，未设置时为 `defaultRoot`。
    public static var `default`: TemplateLibrary {
        TemplateLibrary(root: MacVMSettings.load().templateRoot)
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVM/Templates", directoryHint: .isDirectory)
    }

    public init(root: URL) { storage = VMLibrary(root: root) }

    public func template(named name: String) throws -> VMBundle {
        try VMLibrary.validate(name: name)
        let bundle = VMBundle(url: storage.bundleURL(named: name))
        guard FileManager.default.fileExists(atPath: bundle.configURL.path) else {
            throw MacVMError.templateNotFound(name)
        }
        return bundle
    }

    public func all() throws -> [VMBundle] { try storage.all() }
}
