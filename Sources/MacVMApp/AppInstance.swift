import AppKit
import MacVMModel

/// 每个用户同时只跑一个 App 进程：VZ 虚拟机的生命周期绑在运行它的进程上，
/// 设置与续建记录也是用户级共用的，第二个进程既会抢着续建，退出时又会带走它启动的虚拟机。
/// 不同位置的 App 包（如 /Applications 与调试构建）或直接执行可执行文件启动时，LaunchServices 拦不住，靠这把锁拦。
@MainActor
enum AppInstance {
    private static var lock: ProcessLock?

    /// 取得单实例锁并持有到进程退出；已有别的 App 进程持有时把它切到前台，本进程直接退出。
    /// 锁文件打不开时照常启动：拿不到锁不该让 App 打不开。
    static func claim() {
        let url = MacVMSettings.fileURL.deletingLastPathComponent().appending(path: "app.lock")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let lock = try ProcessLock.acquire(at: url) {
                self.lock = lock
                return
            }
        } catch {
            FileHandle.standardError.write(Data("Could not acquire the single-instance lock: \(error.localizedDescription)\n".utf8))
            return
        }
        let pid = ProcessLock.holder(at: url) ?? -1
        FileHandle.standardError.write(Data("MacVM is already running (pid \(pid)); exiting\n".utf8))
        if pid > 0, let other = NSRunningApplication(processIdentifier: pid) {
            other.activate(options: [.activateAllWindows])
        }
        exit(0)
    }
}
