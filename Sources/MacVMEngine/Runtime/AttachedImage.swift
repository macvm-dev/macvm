public import Foundation
import MacVMModel

/// 运行中以 U 盘接入客户机的磁盘映像，只存在于这次开机，不写进配置。
public struct AttachedImage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let readOnly: Bool

    /// 光盘映像与 DMG 按只读接入，宿主上不可写的文件也是。
    public static func prefersReadOnly(_ url: URL) -> Bool {
        ["iso", "cdr", "dmg"].contains(url.pathExtension.lowercased()) || !FileManager.default.isWritableFile(atPath: url.path)
    }
}

extension MachineRunner {
    /// 接入前的检查：映像不能是本机自己的磁盘，也不能重复接入。
    func checkAttachable(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let own = (config.disks.map(\.path) + config.installMedia).map { bundle.resolve($0).standardizedFileURL.resolvingSymlinksInPath().path }
        if own.contains(path) { throw MacVMError.invalidConfig("\(url.lastPathComponent) 是 \(bundle.name) 自己的磁盘，不能再接入") }
        if attachedImages.contains(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == path }) {
            throw MacVMError.invalidConfig("\(url.lastPathComponent) 已经接入")
        }
        guard FileManager.default.fileExists(atPath: path) else { throw MacVMError.invalidConfig("磁盘映像不存在：\(url.path)") }
    }

    /// 热插的映像不在配置里，恢复时组装不出同样的设备，挂起前要先推出。
    func requireNoAttachedImages() throws {
        guard attachedImages.isEmpty else { throw MacVMError.unsupported("接着磁盘映像时不能挂起，先推出所有磁盘映像") }
    }
}
