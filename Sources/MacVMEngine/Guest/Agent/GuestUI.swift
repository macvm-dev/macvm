public import Foundation
public import MacVMModel

/// 经客户机代理读客户机桌面的无障碍树、操作元素、注入输入与截屏。要求虚拟机在运行、代理支持 `featureUI`。
public enum GuestUI {
    /// 快照遍历几千个元素时要逐个问应用，比一般请求慢得多。
    private static let snapshotTimeout = 120

    public static func snapshot(_ bundle: VMBundle, app: String? = nil, maxDepth: Int? = nil, maxNodes: Int? = nil) throws -> AgentProtocol.UISnapshot {
        try requireSupport(bundle)
        let body = try AgentClient.fetch(.uiSnapshot(app: app, maxDepth: maxDepth, maxNodes: maxNodes), bundle: bundle, timeout: snapshotTimeout)
        do {
            return try JSONDecoder().decode(AgentProtocol.UISnapshot.self, from: body)
        } catch {
            throw MacVMError.engine("客户机代理返回的无障碍树无法解析：\(error.localizedDescription)")
        }
    }

    public static func act(_ bundle: VMBundle, element: String, action: AgentProtocol.ElementAction, value: String? = nil) throws {
        try requireSupport(bundle)
        _ = try AgentClient.call(.uiAction(element: element, action: action, value: value), bundle: bundle)
    }

    public static func input(_ bundle: VMBundle, _ events: [AgentProtocol.InputEvent]) throws {
        try requireSupport(bundle)
        _ = try AgentClient.call(.uiInput(events), bundle: bundle)
    }

    /// 主屏截图（PNG）。QEMU 引擎下代理截不到时（Linux 的 virgl 画面在宿主 GPU 上）改由运行 QEMU 的进程截。
    /// 两边都失败时报两边的原因；代理缺权限时只报代理的，保留 `permissionDenied`。
    public static func screenshot(_ bundle: VMBundle) throws -> Data {
        try requireSupport(bundle)
        do {
            return try AgentClient.fetch(.uiScreenshot, bundle: bundle)
        } catch let agentError {
            guard (try? bundle.loadConfig())?.engine == .qemu else { throw agentError }
            do {
                return try hostScreenshot(bundle)
            } catch {
                if case MacVMError.permissionDenied = agentError { throw agentError }
                throw MacVMError.engine("\(agentError.localizedDescription)；宿主截屏也失败：\(error.localizedDescription)")
            }
        }
    }

    private static func hostScreenshot(_ bundle: VMBundle) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "macvm-ui-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ControlClient.perform(.screenshot(path: url.path), on: bundle)
        return try Data(contentsOf: url)
    }

    private static func requireSupport(_ bundle: VMBundle) throws {
        guard try bundle.loadConfig().guestAgent else {
            throw MacVMError.unsupported("\(bundle.name) 没有安装客户机代理，先运行 macvm agent install \(bundle.name)")
        }
        guard try AgentClient.info(bundle).features?.contains(AgentProtocol.featureUI) == true else {
            throw MacVMError.unsupported("\(bundle.name) 的客户机代理版本过旧，不支持 UI 自动化，先运行 macvm agent install \(bundle.name) 更新")
        }
    }
}
