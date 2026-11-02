public import Foundation
public import MacVMModel

public enum VMStatus {
    /// 从磁盘状态推断，不连接控制 socket，开销只有几次 stat 与一次 flock 探测。
    public static func summary(of bundle: VMBundle) throws -> VMSummary {
        let config = try bundle.loadConfig()
        let pid = BundleLock.holder(of: bundle)
        let state: VMSummary.State = pid != nil ? .running : (bundle.hasSavedState ? .suspended : .stopped)
        let ip = pid == nil ? nil : config.networks.first?.macAddress.flatMap { DHCPLeases.ipAddress(forMAC: $0, hostname: config.name) }
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
}
