public import Foundation
public import MacVMModel

/// 经客户机代理读客户机桌面的无障碍树、操作元素、注入输入与截屏。要求虚拟机在运行、代理支持 `featureUI`。
public enum GuestUI {
    /// 快照遍历几千个元素时要逐个问应用，比一般请求慢得多。
    private static let snapshotTimeout = 120

    public static func snapshot(_ bundle: VMBundle, app: String? = nil, maxDepth: Int? = nil, maxNodes: Int? = nil) throws -> AgentProtocol.UISnapshot {
        try requireSupport(bundle)
        let body = try retryingAfterRestart(bundle) {
            try AgentClient.fetch(.uiSnapshot(app: app, maxDepth: maxDepth, maxNodes: maxNodes), bundle: bundle, timeout: snapshotTimeout)
        }
        do {
            return try JSONDecoder().decode(AgentProtocol.UISnapshot.self, from: body)
        } catch {
            throw MacVMError.engine(String(l10n: "Couldn't parse the accessibility tree from the guest agent: \(error.localizedDescription)"))
        }
    }

    public static func act(_ bundle: VMBundle, element: String, action: AgentProtocol.ElementAction, value: String? = nil) throws {
        try requireSupport(bundle)
        _ = try retryingAfterRestart(bundle) { try AgentClient.call(.uiAction(element: element, action: action, value: value), bundle: bundle) }
    }

    public static func input(_ bundle: VMBundle, _ events: [AgentProtocol.InputEvent]) throws {
        try requireSupport(bundle)
        _ = try retryingAfterRestart(bundle) { try AgentClient.call(.uiInput(events), bundle: bundle) }
    }

    /// 主屏截图（PNG）。QEMU 引擎下代理截不到时（Linux 的 virgl 画面在宿主 GPU 上）改由运行 QEMU 的进程截。
    /// 两边都失败时报两边的原因；代理缺权限时只报代理的，保留 `permissionDenied`。
    public static func screenshot(_ bundle: VMBundle) throws -> Data {
        try requireSupport(bundle)
        do {
            return try retryingAfterRestart(bundle) { try AgentClient.fetch(.uiScreenshot, bundle: bundle) }
        } catch let agentError {
            guard (try? bundle.loadConfig())?.engine == .qemu else { throw agentError }
            do {
                return try hostScreenshot(bundle)
            } catch {
                if case MacVMError.permissionDenied = agentError { throw agentError }
                throw MacVMError.engine(String(l10n: "\(agentError.localizedDescription); couldn't take a screenshot from the host either: \(error.localizedDescription)"))
            }
        }
    }

    private static func hostScreenshot(_ bundle: VMBundle) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "macvm-ui-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ControlClient.perform(.screenshot(path: url.path), on: bundle)
        return try Data(contentsOf: url)
    }

    /// 代理回 `Restarting` 时（macOS 上刚授予的权限要新进程才看得到），等它重启上线后再做一次；再回 `Restarting` 就报错。
    private static func retryingAfterRestart<T>(_ bundle: VMBundle, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let restarting as AgentProtocol.Restarting {
            // 旧进程回完响应过一会儿才退出，先等过这段，免得重试又落在它身上。
            Thread.sleep(forTimeInterval: restartGrace)
            let deadline = Date().addingTimeInterval(restartTimeout)
            while !AgentClient.isReachable(bundle) {
                guard Date() < deadline else { throw restarting.engineError }
                Thread.sleep(forTimeInterval: 0.5)
            }
            do {
                return try body()
            } catch let again as AgentProtocol.Restarting {
                throw again.engineError
            }
        }
    }

    private static let restartGrace: TimeInterval = 1.5
    /// launchd 拉起同一个任务至少间隔 10 秒，留足余量。
    private static let restartTimeout: TimeInterval = 20

    private static func requireSupport(_ bundle: VMBundle) throws {
        guard try bundle.loadConfig().guestAgent else {
            throw MacVMError.unsupported(String(l10n: "The guest agent isn't installed in \(bundle.name); run macvm agent install \(bundle.name) first"))
        }
        guard try AgentClient.info(bundle).features?.contains(AgentProtocol.featureUI) == true else {
            throw MacVMError.unsupported(String(l10n: "The guest agent in \(bundle.name) is too old for UI automation; update it with macvm agent install \(bundle.name)"))
        }
    }
}
