import Foundation

/// 包内 `run.lock` 上的 `ProcessLock`：持有者就是正在运行该虚拟机的进程。
public enum BundleLock {
    /// 已被别的进程持有时抛 `alreadyRunning`。
    public static func acquire(_ bundle: VMBundle) throws -> ProcessLock {
        guard let lock = try ProcessLock.acquire(at: bundle.lockURL) else { throw MacVMError.alreadyRunning(bundle.name) }
        return lock
    }

    /// 返回持有锁的进程 pid；没人持有时为 nil。
    public static func holder(of bundle: VMBundle) -> Int32? { ProcessLock.holder(at: bundle.lockURL) }
}

extension VMBundle {
    /// 改只在冷启动时生效的配置或磁盘之前调用：运行中与挂起（保存的状态绑定原有硬件）时拒绝。
    public func requireStopped() throws {
        if BundleLock.holder(of: self) != nil { throw MacVMError.alreadyRunning(name) }
        if hasSavedState { throw MacVMError.invalidConfig(String(l10n: "\(name) is suspended. Resume it and shut it down before making changes.")) }
    }
}
