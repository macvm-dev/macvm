import Foundation
public import MacVMModel

/// 从客户机内部叫醒按节能设置休眠的显示器：经代理 `exec` 声明一次用户活动。
/// 客户机显示器休眠时不处理宿主改分辨率引起的显示器热插拔：在那之前窗口没有画面，窗口里的键鼠到不了客户机，
/// 醒来后补做的那次热插拔还会让客户机认不出显示器（壁纸变黑）。所以要在画面视图接上虚拟机之前叫醒。
public enum GuestDisplayWake {
    /// 只有装了代理的 macOS 客户机能从内部叫醒。
    public static func isSupported(_ config: VMConfig) -> Bool { config.os == .macOS && config.guestAgent }

    /// 叫醒运行中的 `bundle` 的显示器，等它点亮后返回；代理在 `startLimit` 内没接受命令就不再等。
    /// 用户活动保持 `assertionSeconds`：连接一断代理就结束命令、系统随即撤销用户活动，所以由一条线程守着连接到命令退出。
    public static func wake(_ bundle: VMBundle) async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        Thread.detachNewThread {
            defer { continuation.finish() }
            guard let (response, socket) = try? AgentClient.open(.exec(request), bundle: bundle, timeout: startTimeout), response.ok else { return }
            continuation.yield()
            socket.setTimeout(seconds: assertionSeconds + exitMargin)
            while let header = try? socket.readExact(5) {
                let length = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
                guard AgentProtocol.FrameKind(rawValue: header[0]) != .exit, length <= AgentProtocol.maxFrame,
                      (try? socket.readExact(length)) != nil else { break }
            }
        }
        let limit = Task {
            try? await Task.sleep(for: startLimit)
            continuation.finish()
        }
        defer { limit.cancel() }
        guard await started.first(where: { _ in true }) != nil else { return }
        try? await Task.sleep(for: lightUpDelay)
    }

    /// 用户活动保持的秒数；这期间没有键鼠操作的话，显示器随后按节能设置再休眠。
    static let assertionSeconds = 30
    /// 连上代理后等它回应的秒数。
    private static let startTimeout = 2
    /// 调用方等代理接受命令的上限，连不上代理的那段时间也算在内。
    private static let startLimit: Duration = .seconds(3)
    /// 命令该退出之后再等 `exit` 帧的余量（秒）。
    private static let exitMargin = 10
    /// 客户机里的命令起来后，显示器点亮要的时间。
    private static let lightUpDelay: Duration = .milliseconds(500)

    static let request = AgentProtocol.ExecRequest(argv: ["/usr/bin/caffeinate", "-u", "-t", String(assertionSeconds)])
}
