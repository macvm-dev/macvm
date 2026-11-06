public import Foundation
import MacVMModel

public enum DiskImage {
    /// 创建稀疏 raw 镜像：APFS 上只占已写入的块，且可被 `clonefile` 零拷贝复制。
    public static func createSparse(at url: URL, size: UInt64) throws {
        let length = try fileLength(size)
        // 磁盘里有客户机密码与代理令牌，只给自己读写。
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MacVMError.posix(String(l10n: "Couldn't create disk \(url.path)")) }
        defer { close(fd) }
        guard ftruncate(fd, length) == 0 else {
            let error = MacVMError.posix(String(l10n: "Couldn't set the disk size"))
            unlink(url.path)
            throw error
        }
    }

    /// 只增不减：缩小会截掉客户机文件系统的数据。
    public static func grow(at url: URL, to size: UInt64) throws {
        let current = try allocatedSize(at: url).logical
        guard size > current else {
            throw MacVMError.invalidConfig(String(l10n: "The new size (\(ByteSize.format(size))) must be larger than the current size (\(ByteSize.format(current)))"))
        }
        let length = try fileLength(size)
        guard truncate(url.path, length) == 0 else {
            throw MacVMError.posix(String(l10n: "Couldn't grow \(url.path)"))
        }
    }

    private static func fileLength(_ size: UInt64) throws -> off_t {
        guard let length = off_t(exactly: size) else { throw MacVMError.invalidConfig(String(l10n: "Disk size \(ByteSize.format(size)) is too large")) }
        return length
    }

    /// 把 `staging` 目录做成无分区表的 FAT raw 镜像写到 `output`；`fat32` 为 false 时由 hdiutil 按大小选 FAT 位数。
    static func createFAT(from staging: URL, to output: URL, size: String, volumeName: String, fat32: Bool = false) async throws {
        let dmg = output.deletingPathExtension().appendingPathExtension("dmg")
        let arguments = ["create", "-size", size, "-fs", "MS-DOS"] + (fat32 ? ["-fsargs", "-F 32"] : [])
            + ["-volname", volumeName, "-layout", "NONE", "-format", "UDRW", "-srcfolder", staging.path, "-ov", dmg.path]
        // hdiutil create 偶尔因新建的映像被系统服务短暂占用而失败（Resource busy），隔一会儿重试。
        for attempt in 1... {
            do {
                try await Subprocess.run("/usr/bin/hdiutil", arguments)
                break
            } catch MacVMError.io where attempt < 3 {
                try await Task.sleep(for: .seconds(2))
            }
        }
        try FileManager.default.moveItem(at: dmg, to: output)
    }

    /// logical 是客户机看到的容量，physical 是主机实际占用。
    public static func allocatedSize(at url: URL) throws -> (logical: UInt64, physical: UInt64) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw MacVMError.posix(String(l10n: "Couldn't read \(url.path)")) }
        return (UInt64(st.st_size), UInt64(st.st_blocks) * 512)
    }
}
