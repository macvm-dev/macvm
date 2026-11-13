public import Foundation
public import MacVMModel

/// 客户机里挡住关机的 App。
public enum GuestShutdown {
    /// 调用方已等了 `waited` 秒关机时，代理以登录用户身份发出、还没生效的关机请求期间客户机里仍开着的普通 App；
    /// 不是装了代理的 macOS 客户机、代理不支持这个请求或连不上、这段等待前后没有这样的请求时为空。
    /// 阻塞的 socket 往返，不要在主线程上调用。
    public static func blockingApps(_ bundle: VMBundle, waited: TimeInterval) -> [GuestApp] {
        guard let config = try? bundle.loadConfig(), config.os == .macOS, config.guestAgent,
              let status = try? AgentClient.call(.shutdownStatus, bundle: bundle, timeout: queryTimeout).shutdown,
              status.state != AgentProtocol.ShutdownStatus.stateNone,
              let since = status.sinceMs, Double(since) <= (waited + requestSlack) * 1000
        else { return [] }
        return (status.apps ?? []).map { GuestApp(name: $0.name, bundleId: $0.bundle, pid: $0.pid) }
    }

    private static let queryTimeout = 5
    /// 关机请求可能在调用方开始等待之前不久发出（如先在 App 里点过关机），时间窗比 `waited` 多出这段余量。
    private static let requestSlack: TimeInterval = 30
}
