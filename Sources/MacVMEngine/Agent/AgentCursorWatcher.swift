import CoreGraphics
import Foundation
import MacVMModel

/// 接收客户机代理推送的光标形状（`cursor-watch`）。读在专用线程，回调在主线程；
/// 连接断开或代理不可用时以 `onClose(true)` 结束，代理明确不提供（客户机本次开机自绘光标）时以 `onClose(false)` 结束。
final class AgentCursorWatcher: @unchecked Sendable {
    /// 光标形状与热点（像素）；nil 表示客户机隐藏了光标。
    var onShape: (@MainActor (CGImage?, CGPoint) -> Void)?
    /// 参数表示稍后重试是否可能成功。
    var onClose: (@MainActor (Bool) -> Void)?

    private let bundle: VMBundle
    private let lock = NSLock()
    private var socket: UnixSocket?
    private var closed = false

    init(bundle: VMBundle) { self.bundle = bundle }

    func start() {
        let thread = Thread { [self] in
            let retry = run()
            let onClose = onClose
            Task { @MainActor in onClose?(retry) }
        }
        thread.name = "macvm.cursor"
        thread.start()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        if let socket { shutdown(socket.fd, SHUT_RDWR) }
    }

    private func run() -> Bool {
        guard let (response, socket) = try? AgentClient.open(.cursorWatch, bundle: bundle, timeout: 5) else { return true }
        guard response.ok else { return false }
        lock.lock()
        let cancelled = closed
        if !cancelled { self.socket = socket }
        lock.unlock()
        guard !cancelled else { return false }
        socket.setTimeout(seconds: 0)
        let decoder = JSONDecoder()
        while let line = try? socket.readLine(), let shape = try? decoder.decode(AgentProtocol.CursorShape.self, from: line) {
            let image = shape.hidden ? nil : Data(base64Encoded: shape.bgra).flatMap { cursorImage(bgra: $0, width: shape.width, height: shape.height) }
            let hotspot = CGPoint(x: shape.hot_x, y: shape.hot_y), onShape = onShape
            Task { @MainActor [image] in onShape?(image, hotspot) }
        }
        return true
    }
}
