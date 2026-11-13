public import Foundation
public import MacVMModel

public enum VMStatus {
    /// 从磁盘状态推断，不连接控制 socket，开销只有几次 stat 与一次 flock 探测。
    public static func summary(of bundle: VMBundle) throws -> VMSummary { try summary(of: bundle, leases: Leases()) }

    /// 库里所有能读出配置的虚拟机；租约表最多读一次。
    public static func summaries(in library: VMLibrary) -> [VMSummary] {
        let leases = Leases()
        return ((try? library.all()) ?? []).compactMap { try? summary(of: $0, leases: leases) }
    }

    /// 有运行中的虚拟机要查 IP 时才读租约表。
    private final class Leases {
        lazy var text = DHCPLeases.read()
    }

    private static func summary(of bundle: VMBundle, leases: Leases) throws -> VMSummary {
        let config = try bundle.loadConfig()
        let pid = BundleLock.holder(of: bundle)
        let state: VMSummary.State = pid != nil ? .running : (bundle.hasSavedState ? .suspended : .stopped)
        // 客户机在租约里报的是安装时由虚拟机名规整出的主机名。
        let hostname = CloudInit.hostname(for: config.name, fallback: config.name)
        let ip = pid == nil ? nil : GuestAddress.current(bundle, config, hostname: hostname) { leases.text }
        return VMSummary(
            name: config.name, os: config.os, state: state,
            cpuCount: config.cpuCount, memorySize: config.memorySize,
            path: bundle.url.path, pid: pid, ipAddress: ip
        )
    }

    /// 轮询直到 `condition` 成立或超时。
    public static func poll(
        timeout: TimeInterval,
        interval: TimeInterval = 0.25,
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .seconds(interval))
        }
        return try condition()
    }

    /// 等到没有进程持有 `bundle` 的运行锁；超时返回 false。
    public static func waitUntilStopped(_ bundle: VMBundle, timeout: TimeInterval) async throws -> Bool {
        try await poll(timeout: timeout) { BundleLock.holder(of: bundle) == nil }
    }

    /// 等到查得到 `bundle` 的 IP 地址；超时返回 nil。
    public static func waitForIPAddress(_ bundle: VMBundle, timeout: TimeInterval, interval: TimeInterval) async throws -> String? {
        var ip: String?
        _ = try await poll(timeout: timeout, interval: interval) {
            ip = try summary(of: bundle).ipAddress
            return ip != nil
        }
        return ip
    }
}
