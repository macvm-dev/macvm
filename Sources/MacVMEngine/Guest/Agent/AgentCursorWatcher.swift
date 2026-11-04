import CoreGraphics
import Foundation
import MacVMModel

/// 宿主要显示的客户机光标。
enum GuestCursor: @unchecked Sendable {
    /// 宿主不画光标：客户机隐藏了光标，或光标由客户机自己画。
    case hidden
    /// 图像与热点（像素）。
    case image(CGImage, hotspot: CGPoint)
    /// 客户机系统光标的种类（`CursorShape.system`），宿主换成自己的同类光标。
    case system(String)
}

/// 接收客户机代理推送的光标形状（`cursor-watch`）。读在专用线程，回调在主线程；
/// 连接断开或代理不可用时以 `onClose(true)` 结束，代理明确不提供（客户机自绘光标，如 VZ 下）时以 `onClose(false)` 结束。
final class AgentCursorWatcher: @unchecked Sendable {
    /// 光标宽高的上限。尺寸来自不可信的客户机，超出的当作无效形状，也免得算图像字节数时整数溢出。
    static let maxCursorSide = 1024

    var onShape: (@MainActor (GuestCursor) -> Void)?
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
            let cursor: GuestCursor
            if shape.hidden {
                cursor = .hidden
            } else if let kind = shape.system {
                cursor = .system(kind)
            } else if shape.width <= Self.maxCursorSide, shape.height <= Self.maxCursorSide,
                      let image = Data(base64Encoded: shape.bgra).flatMap({ cursorImage(bgra: $0, width: shape.width, height: shape.height) }) {
                cursor = .image(image, hotspot: CGPoint(x: shape.hot_x, y: shape.hot_y))
            } else {
                cursor = .hidden
            }
            let onShape = onShape
            Task { @MainActor in onShape?(cursor) }
        }
        return true
    }
}
