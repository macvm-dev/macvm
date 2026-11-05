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

    /// 主屏截图（PNG）。
    public static func screenshot(_ bundle: VMBundle) throws -> Data {
        try requireSupport(bundle)
        return try AgentClient.fetch(.uiScreenshot, bundle: bundle)
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
