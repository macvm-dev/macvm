import CryptoKit
import Foundation
import MacVMModel

/// Windows 的 3D 显卡驱动 viogpu3d，随自带的 QEMU 提供。宿主把它放进客户机的 `guestDirectory`，
/// 客户机代理在 QEMU 下开机时装到在场的 virtio-gpu 上；放进去之后这台虚拟机就只能用带 3D 的 QEMU 运行
/// （`VMConfig.graphicsAcceleration`）。
enum WindowsGPUDriver {
    /// 客户机代理从这个目录读驱动包；路径是与代理的约定，宿主这边不能单方面改。
    static let guestDirectory = AgentInstaller.windowsDirectory + #"\viogpu3d"#

    /// 自带的 QEMU 编进了 Direct3D 转译时才有。
    static func package(_ qemu: QEMUInstallation?) -> URL? {
        guard let qemu, qemu.direct3D, let root = qemu.bundleRoot else { return nil }
        let zip = root.appending(path: "share/viogpu3d-arm64x-signed.zip")
        return FileManager.default.fileExists(atPath: zip.path) ? zip : nil
    }

    /// 代理没在听（客户机还在开机、尚未登录）：稍后再推。
    struct AgentNotReady: Error {}

    /// 读进内存的驱动包与它的 SHA-256，等代理上线时反复推送用同一份。
    struct Payload: Sendable {
        let data: Data
        let sha256: String

        init(contentsOf zip: URL) throws {
            data = try Data(contentsOf: zip)
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// 把驱动包推给客户机代理（`connect` 连到代理端口）：代理已有同一个包时什么也不做，
    /// 否则收下后立即安装。返回客户机是否换了驱动。
    static func push(_ payload: Payload, connect: () throws -> UnixSocket) throws -> Bool {
        guard let socket = try? connect() else { throw AgentNotReady() }
        socket.setTimeout(seconds: 30)
        let request = AgentProtocol.Request.gpuDriver(sha256: payload.sha256, size: payload.data.count)
        guard let first = try? socket.exchange(request, as: AgentProtocol.Response.self) else { throw AgentNotReady() }
        guard try first.checked().text == "send" else { return false }
        try socket.writeAll(payload.data)
        // 装驱动要十几秒。
        socket.setTimeout(seconds: 180)
        guard let last = try socket.readLine() else { throw MacVMError.io("客户机代理在安装显卡驱动时关闭了连接") }
        return try JSONDecoder().decode(AgentProtocol.Response.self, from: last).checked().text == "installed"
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
