import CryptoKit
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

    /// 代理没在听（客户机还在开机、尚未登录）：稍后再推。
    struct AgentNotReady: Error {}

    /// 把驱动包推给客户机代理（`socketPath` 是代理端口转发出来的 socket）：代理已有同一个包时什么也不做，
    /// 否则收下后立即安装。返回客户机是否换了驱动。
    static func push(_ zip: URL, to socketPath: String) throws -> Bool {
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let socket = try? UnixSocket.connect(to: socketPath) else { throw AgentNotReady() }
        socket.setTimeout(seconds: 30)
        guard (try? socket.writeLine(JSONEncoder().encode(AgentProtocol.Request.gpuDriver(sha256: digest, size: data.count)))) != nil,
              let first = try? socket.readLine() else { throw AgentNotReady() }
        guard try response(first).text == "send" else { return false }
        try socket.writeAll(data)
        // 装驱动要十几秒。
        socket.setTimeout(seconds: 180)
        guard let last = try socket.readLine() else { throw MacVMError.io("客户机代理在安装显卡驱动时关闭了连接") }
        return try response(last).text == "installed"
    }

    private static func response(_ line: Data) throws -> AgentProtocol.Response {
        let response = try JSONDecoder().decode(AgentProtocol.Response.self, from: line)
        guard response.ok else { throw MacVMError.engine("客户机代理：\(response.error ?? "未知错误")") }
        return response
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
