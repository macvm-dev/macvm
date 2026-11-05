public import MacVMModel

/// 经客户机代理读写客户机的文本剪贴板。macOS 与 Windows 客户机的代理支持；Linux 客户机的剪贴板经 SPICE 代理同步（`ConfigBuilder.configureClipboard`）。
public enum GuestClipboard {
    /// 剪贴板跟着窗口焦点同步，用户等着粘贴，代理连不上时宁可这次不同步也不要久等。
    private static let timeout = 3
    /// 文本的 UTF-8 字节数上限。请求与响应都是一行不超过 `AgentProtocol.maxFrame` 的 JSON，转义会变长，留一半余量。
    public static let maxText = AgentProtocol.maxFrame / 2

    /// 是否经代理同步剪贴板。
    public static func enabled(_ config: VMConfig) -> Bool {
        config.clipboard && config.guestAgent && config.os != .linux
    }

    public static func text(_ bundle: VMBundle) throws -> String {
        try AgentClient.call(.clipboardGet, bundle: bundle, timeout: timeout).text ?? ""
    }

    public static func setText(_ bundle: VMBundle, _ text: String) throws {
        guard text.utf8.count <= maxText else { throw MacVMError.unsupported("剪贴板文本超过 \(maxText) 字节，不同步") }
        _ = try AgentClient.call(.clipboardSet(text: text), bundle: bundle, timeout: timeout)
    }
}
