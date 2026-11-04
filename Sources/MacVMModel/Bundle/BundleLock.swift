import Foundation

/// 包内 `run.lock` 上的独占 flock：持有者就是正在运行该虚拟机的进程。
/// 锁随进程退出自动释放，不会因崩溃残留；文件内容是持有者 pid，仅供展示。
public final class BundleLock: @unchecked Sendable {
    private var fd: Int32
    private let mutex = NSLock()

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    /// 立即释放；虚拟机停止后调用，不等持有者被回收。可重复调用。
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    /// 已被别的进程持有时抛 `alreadyRunning`。
    public static func acquire(_ bundle: VMBundle) throws -> BundleLock {
        let fd = open(bundle.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MacVMError.posix("打开 \(bundle.lockURL.path)") }
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

extension VMBundle {
    /// 改只在冷启动时生效的配置或磁盘之前调用：运行中与挂起（保存的状态绑定原有硬件）时拒绝。
    public func requireStopped() throws {
        if BundleLock.holder(of: self) != nil { throw MacVMError.alreadyRunning(name) }
        if hasSavedState { throw MacVMError.invalidConfig("\(name) 已挂起，继续运行再关机后才能修改") }
    }
}
