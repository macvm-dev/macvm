public import Foundation

/// 文件上的独占 flock：持有者就是占用该资源的进程。
/// 锁随进程退出自动释放，不会因崩溃残留；文件内容是持有者 pid，仅供展示。
public final class ProcessLock: @unchecked Sendable {
    private var fd: Int32
    private let mutex = NSLock()

    private static let busyRetries = 5
    /// 微秒。
    private static let busyRetryInterval: useconds_t = 2_000

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    /// 立即释放，不等持有者被回收。可重复调用。
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    /// 取得锁；已被别的进程持有时返回 nil。
    public static func acquire(at url: URL) throws -> ProcessLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MacVMError.posix("打开 \(url.path)") }
        // 拿不到时稍等重试：别的进程探测持有者时也会短暂占着锁，那不算被持有。
        var attempts = 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard attempts < busyRetries else {
                close(fd)
                return nil
            }
            attempts += 1
            usleep(busyRetryInterval)
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return ProcessLock(fd: fd)
    }

    /// 返回持有锁的进程 pid；没人持有时为 nil，读不出 pid 时为 -1。
    public static func holder(at url: URL) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
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
