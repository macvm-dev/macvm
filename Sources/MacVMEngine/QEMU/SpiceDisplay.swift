import AppKit
import Darwin

/// `QEMUDisplayView` 的画面来源：VNC 或 SPICE。坐标与按钮位都按 VNC 的约定（客户机像素；1 左、2 中、4 右）。
@MainActor
protocol DisplayBackend: AnyObject {
    func sendPointer(buttons: UInt8, x: UInt16, y: UInt16)
    /// `up` 为真时向上滚一格。
    func scroll(up: Bool, buttons: UInt8, x: UInt16, y: UInt16)
    /// `qnum` 为第 1 套扫描码，E0 前缀键为 0x80 | 第二字节。
    func sendKey(qnum: UInt32, down: Bool)
    func close()
}

extension VNCClient: DisplayBackend {
    func scroll(up: Bool, buttons: UInt8, x: UInt16, y: UInt16) {
        sendPointer(buttons: buttons | (up ? 8 : 16), x: x, y: y)
        sendPointer(buttons: buttons, x: x, y: y)
    }

    func sendKey(qnum: UInt32, down: Bool) { sendKey(scancode: qnum, down: down) }
}

/// 经 libMacVMDisplay（CocoaSpice）显示 SPICE 画面：GL 画面在 QEMU 与本进程间经 IOSurface 共享，不拷像素。
@MainActor
final class SpiceDisplay: DisplayBackend {
    /// 画面视图，铺满宿主视图；它不接收鼠标事件，键鼠由宿主视图转发。
    let view: NSView
    var onConnect: (() -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onClose: (() -> Void)?

    private let library: Library
    private let handle: UnsafeMutableRawPointer
    private var closed = false

    /// 库加载失败或 socket 尚不存在时返回 nil。
    init?(socketPath: String, library url: URL) {
        guard FileManager.default.fileExists(atPath: socketPath), let library = Library.load(url) else { return nil }
        self.library = library
        let box = Box()
        guard let handle = socketPath.withCString({ library.create($0, Self.handler, Unmanaged.passUnretained(box).toOpaque()) }) else {
            return nil
        }
        self.handle = handle
        view = Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
        self.box = box
        box.owner = self
    }

    /// 回调的上下文：库只持有它的裸指针，`close` 之后库不再回调。
    @MainActor private final class Box { weak var owner: SpiceDisplay? }
    private let box: Box

    private static let handler: Library.Handler = { context, event, width, height in
        guard let context else { return }
        let address = UInt(bitPattern: context)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address),
                  let owner = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue().owner else { return }
            switch event {
            case 1: owner.onConnect?()
            case 2: owner.onClose?()
            case 3: owner.onResize?(CGSize(width: width, height: height))
            default: break
            }
        }
    }

    func sendPointer(buttons: UInt8, x: UInt16, y: UInt16) {
        library.pointer(handle, Double(x), Double(y), UInt32(buttons))
    }

    func scroll(up: Bool, buttons: UInt8, x: UInt16, y: UInt16) {
        library.pointer(handle, Double(x), Double(y), UInt32(buttons))
        library.scroll(handle, up, UInt32(buttons))
    }

    /// SPICE 的扩展键写成 0x100 | 第二字节。
    func sendKey(qnum: UInt32, down: Bool) {
        let code = qnum & 0x80 != 0 && qnum > 0x80 ? 0x100 | (qnum & 0x7f) : qnum
        library.key(handle, Int32(code), down)
    }

    /// 宿主已用系统光标显示客户机光标时，不再把 SPICE 光标画进画面。
    func showGuestCursor(_ shows: Bool) { library.showGuestCursor(handle, shows) }

    func close() {
        guard !closed else { return }
        closed = true
        library.close(handle)
        view.removeFromSuperview()
        Unmanaged<NSView>.fromOpaque(handle).release()
    }

    /// `MacVMDisplay.h` 的函数表，进程内只加载一次。
    struct Library {
        typealias Handler = @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double) -> Void
        let create: @convention(c) (UnsafePointer<CChar>, Handler, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        let close: @convention(c) (UnsafeMutableRawPointer) -> Void
        let key: @convention(c) (UnsafeMutableRawPointer, Int32, Bool) -> Void
        let pointer: @convention(c) (UnsafeMutableRawPointer, Double, Double, UInt32) -> Void
        let scroll: @convention(c) (UnsafeMutableRawPointer, Bool, UInt32) -> Void
        let showGuestCursor: @convention(c) (UnsafeMutableRawPointer, Bool) -> Void

        @MainActor private static var loaded: [URL: Library] = [:]

        @MainActor static func load(_ url: URL) -> Library? {
            if let cached = loaded[url] { return cached }
            guard let lib = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let create = symbol("MacVMDisplayCreate", (@convention(c) (UnsafePointer<CChar>, Handler, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self),
                  let close = symbol("MacVMDisplayClose", (@convention(c) (UnsafeMutableRawPointer) -> Void).self),
                  let key = symbol("MacVMDisplayKey", (@convention(c) (UnsafeMutableRawPointer, Int32, Bool) -> Void).self),
                  let pointer = symbol("MacVMDisplayPointer", (@convention(c) (UnsafeMutableRawPointer, Double, Double, UInt32) -> Void).self),
                  let scroll = symbol("MacVMDisplayScroll", (@convention(c) (UnsafeMutableRawPointer, Bool, UInt32) -> Void).self),
                  let showGuestCursor = symbol("MacVMDisplayShowGuestCursor", (@convention(c) (UnsafeMutableRawPointer, Bool) -> Void).self)
            else { return nil }
            let library = Library(create: create, close: close, key: key, pointer: pointer, scroll: scroll, showGuestCursor: showGuestCursor)
            loaded[url] = library
            return library
        }
    }
}
