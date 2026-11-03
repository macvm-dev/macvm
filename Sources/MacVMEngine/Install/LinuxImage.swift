public import Foundation
import MacVMModel

/// 可直接启动的 Linux 云镜像。只收录发行方提供 raw 磁盘（打包在 tar 里）的镜像，
/// 免去主机上的格式转换；镜像内须带 cloud-init 以完成用户与密钥注入。
public struct LinuxImage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let url: URL
    /// 归档里磁盘文件的扩展名。
    let diskExtension: String

    public static let catalog: [LinuxImage] = [
        LinuxImage(
            id: "debian-13", title: "Debian 13 (trixie) genericcloud",
            url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.tar.xz")!,
            diskExtension: "raw"
        ),
        LinuxImage(
            id: "ubuntu-24.04", title: "Ubuntu 24.04 LTS (noble) server cloudimg",
            url: URL(string: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.tar.gz")!,
            diskExtension: "img"
        ),
    ]

    public static func named(_ id: String) throws -> LinuxImage {
        guard let image = catalog.first(where: { $0.id == id }) else {
            throw MacVMError.invalidConfig("未知镜像 \(id)，可选：\(catalog.map(\.id).joined(separator: ", "))")
        }
        return image
    }
}

/// 下载并解包后的镜像缓存，位于 `~/Library/Caches/MacVM/images`。
public enum ImageCache {
    public static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVM/images", directoryHint: .isDirectory)
    }

    /// 返回解包好的 raw 磁盘，不在缓存里时先下载；`showProgress` 为 true 时把下载进度写到 stderr。
    public static func disk(for image: LinuxImage, showProgress: Bool) async throws -> URL {
        let disk = root.appending(path: "\(image.id).raw")
        if FileManager.default.fileExists(atPath: disk.path) { return disk }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appending(path: image.url.lastPathComponent + ".part")
        try await Subprocess.run("/usr/bin/curl", ["-fL", "--retry", "3", "-C", "-", showProgress ? "--progress-bar" : "-sS", "-o", archive.path, image.url.absoluteString],
                                 passthroughStderr: showProgress)

        let staging = root.appending(path: "\(image.id).staging", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Subprocess.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])

        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let extracted = files.first(where: { $0.pathExtension == image.diskExtension }) else {
            throw MacVMError.io("镜像归档里没有 .\(image.diskExtension) 磁盘")
        }
        try FileManager.default.moveItem(at: extracted, to: disk)
        try? FileManager.default.removeItem(at: archive)
        return disk
    }
}
