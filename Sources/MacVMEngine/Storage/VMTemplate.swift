import Foundation
public import MacVMModel

/// 把已停止的虚拟机存为模板，再从模板新建虚拟机。两步都是 `VMClone` 复制：模板与每台由它新建的虚拟机
/// 各有自己的机器标识与 MAC，客户机密码与代理令牌沿用源机的；快照与挂起状态不进模板。
public enum VMTemplate {
    /// 源虚拟机须已关机，挂起的也不行：挂起时磁盘停在运行中途，存下的模板开机就像断过电。
    public static func save(_ source: VMBundle, as name: String, in templates: TemplateLibrary = .default) async throws -> VMBundle {
        try source.requireStopped()
        return try await VMClone.clone(source, as: name, in: templates.storage)
    }

    /// 给了 `diskSize` 时系统盘扩大到它，不能比模板的小。`configure` 在保存新虚拟机的配置前调用，抛错时不留下新虚拟机。
    public static func instantiate(_ template: VMBundle, as name: String, in library: VMLibrary = .default,
                                   cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64? = nil,
                                   creationToken: String? = nil,
                                   configure: (inout VMConfig) throws -> Void = { _ in }) async throws -> VMBundle {
        try await VMClone.clone(template, as: name, in: library, creationToken: creationToken) { config, bundle in
            if let cpuCount { config.cpuCount = cpuCount }
            if let memorySize { config.memorySize = memorySize }
            if let diskSize, diskSize != (try DiskImage.allocatedSize(at: bundle.diskURL).logical) {
                try DiskImage.grow(at: bundle.diskURL, to: diskSize)
            }
            try configure(&config)
        }
    }

    /// 没有配置的半成品（存模板中途被终止留下的）也删：它不出现在列表里，却占着名字。
    public static func delete(named name: String, in templates: TemplateLibrary = .default) throws {
        try VMLibrary.validate(name: name)
        let url = templates.storage.bundleURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MacVMError.templateNotFound(name) }
        try VMFactory.delete(VMBundle(url: url))
    }

    public static func summary(of template: VMBundle) throws -> TemplateSummary {
        let config = try template.loadConfig()
        return TemplateSummary(name: template.name, os: config.os, engine: config.engine, cpuCount: config.cpuCount,
                               memorySize: config.memorySize, diskSize: try? DiskImage.allocatedSize(at: template.diskURL).logical,
                               path: template.url.path)
    }

    /// 目录里所有能读出配置的模板。
    public static func summaries(in templates: TemplateLibrary = .default) -> [TemplateSummary] {
        ((try? templates.all()) ?? []).compactMap { try? summary(of: $0) }
    }
}
