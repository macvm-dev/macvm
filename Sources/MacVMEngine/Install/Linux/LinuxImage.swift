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

    /// Debian 用 generic 而非 genericcloud：后者的 cloud 内核不带 DRM，virtio-gpu 无驱动，
    /// 窗口画面会停在 EFI 引导输出。
    public static let catalog: [LinuxImage] = [
        LinuxImage(
            id: "debian-13", title: "Debian 13 (trixie) generic",
            url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz")!,
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

    /// 解包后的磁盘在缓存里的文件名，取自归档名，使换了下载地址的镜像不复用旧缓存。
    var cacheFileName: String {
        var name = url.lastPathComponent
        for suffix in [".tar.xz", ".tar.gz"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name + ".raw"
    }
}

/// 下载并解包后的镜像缓存，位于 `DownloadCache.root` 下的 images。
public enum ImageCache {
    public static var root: URL {
        DownloadCache.root.appending(path: "images", directoryHint: .isDirectory)
    }

    /// 返回解包好的 raw 磁盘，不在缓存里时先下载；`showProgress` 为 true 时把下载进度写到 stderr。
    public static func disk(for image: LinuxImage, showProgress: Bool) async throws -> URL {
        // 只取一次：下载期间设置里的目录可能被改，中间文件得留在同一处。
        let root = root
        let disk = root.appending(path: image.cacheFileName)
        let archive = root.appending(path: image.url.lastPathComponent + ".part")
        return try await Download.cached(disk, from: image.url, via: archive, showProgress: showProgress) { archive in
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
        }
    }
}
