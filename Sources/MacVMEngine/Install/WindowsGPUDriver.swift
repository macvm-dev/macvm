import Foundation
import MacVMModel

/// Windows 的 3D 显卡驱动 viogpu3d，随自带的 QEMU 提供。宿主把它放进客户机的 `guestDirectory`，
/// 客户机代理在 QEMU 下开机时装到在场的 virtio-gpu 上；放进去之后这台虚拟机就只能用带 3D 的 QEMU 运行
/// （`VMConfig.graphicsAcceleration`）。
enum WindowsGPUDriver {
    /// 客户机代理找驱动包的目录，与代理的 `GPU_DRIVER_DIR` 相同。
    static let guestDirectory = #"C:\ProgramData\macvm\viogpu3d"#

    /// 自带的 QEMU 编进了 Direct3D 转译时才有。
    static func package(_ qemu: QEMUInstallation?) -> URL? {
        guard let qemu, qemu.direct3D, let root = qemu.bundleRoot else { return nil }
        let zip = root.appending(path: "share/viogpu3d-arm64x-signed.zip")
        return FileManager.default.fileExists(atPath: zip.path) ? zip : nil
    }

    /// 把驱动包里的 INF、目录文件、内核与用户态驱动平铺解到 `directory`。
    static func extract(_ zip: URL, to directory: URL) async throws {
        let unpacked = FileManager.default.temporaryDirectory.appending(path: "macvm-viogpu3d-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try await Subprocess.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let source = unpacked.appending(path: "drivers/viogpu3d")
        guard FileManager.default.fileExists(atPath: source.appending(path: "viogpu3d.inf").path) else {
            throw MacVMError.io("驱动包里没有 viogpu3d.inf：\(zip.path)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.copyItem(at: source.appending(path: name), to: directory.appending(path: name))
        }
    }
}
