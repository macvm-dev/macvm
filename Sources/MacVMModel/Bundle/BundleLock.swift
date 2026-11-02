public import Foundation

/// 包内 `run.lock` 上的独占 flock：持有者就是正在运行该虚拟机的进程。
/// 锁随进程退出自动释放，不会因崩溃残留；文件内容是持有者 pid，仅供展示。
public final class BundleLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    /// 已被别的进程持有时抛 `alreadyRunning`。
    public static func acquire(_ bundle: VMBundle) throws -> BundleLock {
        let fd = open(bundle.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MacVMError.io("打开 \(bundle.lockURL.path) 失败：\(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MacVMError.alreadyRunning(bundle.name)
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return BundleLock(fd: fd)
    }

    /// 返回持有锁的进程 pid；没人持有时为 nil。
    public static func holder(of bundle: VMBundle) -> Int32? {
        let fd = open(bundle.lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return -1 }
        return Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
