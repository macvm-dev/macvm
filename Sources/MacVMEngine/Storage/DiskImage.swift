public import Foundation
public import MacVMModel

public enum DiskImage {
    /// 创建稀疏 raw 镜像：APFS 上只占已写入的块，且可被 `clonefile` 零拷贝复制。
    public static func createSparse(at url: URL, size: UInt64) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MacVMError.io("创建磁盘 \(url.path) 失败：\(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(url.path)
            throw MacVMError.io("设置磁盘大小失败：\(message)")
        }
    }

    /// 只增不减：缩小会截掉客户机文件系统的数据。
    public static func grow(at url: URL, to size: UInt64) throws {
        let current = try allocatedSize(at: url).logical
        guard size > current else {
            throw MacVMError.invalidConfig("新大小 \(ByteSize.format(size)) 不大于当前 \(ByteSize.format(current))")
        }
        guard truncate(url.path, off_t(size)) == 0 else {
            throw MacVMError.io("扩容 \(url.path) 失败：\(String(cString: strerror(errno)))")
        }
    }

    /// logical 是客户机看到的容量，physical 是主机实际占用。
    public static func allocatedSize(at url: URL) throws -> (logical: UInt64, physical: UInt64) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw MacVMError.io("读取 \(url.path) 失败：\(String(cString: strerror(errno)))") }
        return (UInt64(st.st_size), UInt64(st.st_blocks) * 512)
    }
}
