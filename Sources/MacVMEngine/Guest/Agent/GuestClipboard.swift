public import Foundation
public import MacVMModel

/// 经客户机代理读写客户机的剪贴板：文本，以及代理支持 `AgentProtocol.featureFiles` 时的文件。
/// macOS 与 Windows 客户机的代理支持；Linux 客户机的剪贴板经 SPICE 代理同步（`ConfigBuilder.configureClipboard`）。
public enum GuestClipboard {
    /// 剪贴板跟着窗口焦点同步，用户等着粘贴，代理连不上时宁可这次不同步也不要久等。
    private static let timeout = 3
    /// 文本的 UTF-8 字节数上限。请求与响应都是一行不超过 `AgentProtocol.maxFrame` 的 JSON，转义会变长，留一半余量。
    public static let maxText = AgentProtocol.maxFrame / 2
    /// 随焦点切换自动复制的文件总量上限；更大的文件让用户拖进窗口或用共享目录，免得切个窗口就开始长时间复制。
    public static let maxFiles: Int64 = 2 << 30

    /// 客户机剪贴板的内容。有文件时 `text` 通常是文件名，同步时以文件为准。
    public struct Contents: Equatable, Sendable {
        public var text: String
        public var files: [AgentProtocol.GuestFile]

        public init(text: String, files: [AgentProtocol.GuestFile] = []) {
            self.text = text
            self.files = files
        }
    }

    /// 是否经代理同步剪贴板。
    public static func enabled(_ config: VMConfig) -> Bool {
        config.clipboard && config.guestAgent && config.os != .linux
    }

    public static func contents(_ bundle: VMBundle) throws -> Contents {
        let response = try AgentClient.call(.clipboardGet, bundle: bundle, timeout: timeout)
        return Contents(text: response.text ?? "", files: response.files ?? [])
    }

    public static func setText(_ bundle: VMBundle, _ text: String) throws {
        guard text.utf8.count <= maxText else { throw MacVMError.unsupported(String(l10n: "Clipboard text over \(maxText) bytes isn't synced")) }
        _ = try AgentClient.call(.clipboardSet(text: text), bundle: bundle, timeout: timeout)
    }

    /// 把宿主上的文件复制进客户机的暂存目录，并把客户机剪贴板换成它们。
    public static func setFiles(_ bundle: VMBundle, _ urls: [URL], progress: Progress) throws {
        try GuestFileTransfer.requireSupport(bundle)
        try GuestFileTransfer.send(urls, to: .clipboard, bundle: bundle, progress: progress)
    }
}
