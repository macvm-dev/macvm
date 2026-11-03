public import AppKit
public import MacVMModel

/// 显示 QEMU 虚拟机画面并转发键鼠的视图，连接 `QEMUCommand.vncSocket` 上的 VNC。
/// 不要求虚拟机在本进程运行：`macvm start` 在后台运行的虚拟机同样能显示。
/// 客户机分辨率由客户机决定，画面按比例缩放进视图。
public final class QEMUDisplayView: NSView {
    private let socketPath: String
    private var client: VNCClient?
    private var framebufferSize = CGSize.zero
    private var reconnect: Timer?
    private var buttons: UInt8 = 0
    private var scrollAccumulator: CGFloat = 0
    private var pressedModifiers: Set<UInt16> = []

    public init(bundle: VMBundle) {
        socketPath = QEMUCommand.vncSocket(bundle).path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            connect()
            window?.makeFirstResponder(self)
        } else {
            disconnect()
        }
    }

    /// 停止画面传输；虚拟机继续运行。
    public func disconnect() {
        reconnect?.invalidate()
        reconnect = nil
        client?.onClose = nil
        client?.close()
        client = nil
    }

    private func connect() {
        guard client == nil else { return }
        do {
            let client = try VNCClient(path: socketPath)
            client.onFrame = { [weak self] image, size in
                self?.framebufferSize = size
                self?.layer?.contents = image
            }
            client.onClose = { [weak self] in
                self?.client = nil
                self?.scheduleReconnect()
            }
            self.client = client
            client.start()
        } catch {
            scheduleReconnect()
        }
    }

    /// 虚拟机还在启动或刚重启时 socket 尚不可用，过一会儿再连。
    private func scheduleReconnect() {
        guard window != nil, reconnect == nil else { return }
        reconnect = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconnect = nil
                self?.connect()
            }
        }
    }

    // MARK: - 光标

    /// 客户机自己在画面里画光标，指针在视图里且窗口在前台时隐藏宿主光标，免得出现两个。
    /// `NSCursor.hide` 按次数计、作用于整个应用，所以只在状态变化时调用一次并在离开、失焦、移除时恢复。
    private var cursorHidden = false
    private var keyObservers: [any NSObjectProtocol] = []

    private func updateCursor() {
        let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        let hide = inside && window?.isKeyWindow == true
        guard hide != cursorHidden else { return }
        cursorHidden = hide
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
    }

    public override func mouseEntered(with event: NSEvent) { updateCursor() }
    public override func mouseExited(with event: NSEvent) { updateCursor() }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if cursorHidden {
            cursorHidden = false
            NSCursor.unhide()
        }
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCursor() }
            })
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - 鼠标

    /// 视图坐标换算为帧缓冲坐标，与 `.resizeAspect` 的留边一致。
    private func framebufferPoint(_ event: NSEvent) -> (UInt16, UInt16)? {
        guard framebufferSize.width > 0, framebufferSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let origin = CGPoint(x: (bounds.width - framebufferSize.width * scale) / 2, y: (bounds.height - framebufferSize.height * scale) / 2)
        let x = min(max((p.x - origin.x) / scale, 0), framebufferSize.width - 1)
        let y = min(max((p.y - origin.y) / scale, 0), framebufferSize.height - 1)
        return (UInt16(x), UInt16(y))
    }

    private func sendPointer(_ event: NSEvent, buttons extra: UInt8 = 0) {
        guard let (x, y) = framebufferPoint(event) else { return }
        client?.sendPointer(buttons: buttons | extra, x: x, y: y)
    }

    private func setButton(_ bit: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(event)
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor()
        sendPointer(event)
    }
    public override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setButton(1, down: true, event)
    }
    public override func mouseUp(with event: NSEvent) { setButton(1, down: false, event) }
    public override func rightMouseDown(with event: NSEvent) { setButton(4, down: true, event) }
    public override func rightMouseUp(with event: NSEvent) { setButton(4, down: false, event) }
    public override func otherMouseDown(with event: NSEvent) { setButton(2, down: true, event) }
    public override func otherMouseUp(with event: NSEvent) { setButton(2, down: false, event) }

    /// 滚轮在 VNC 里是按键 4（上）与 5（下）的一次按下松开；触控板的连续滚动累计到一格再发。
    public override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulator += event.scrollingDeltaY
        while abs(scrollAccumulator) >= step {
            let bit: UInt8 = scrollAccumulator > 0 ? 8 : 16
            sendPointer(event, buttons: bit)
            sendPointer(event)
            scrollAccumulator -= scrollAccumulator > 0 ? step : -step
        }
    }

    // MARK: - 键盘

    public override func keyDown(with event: NSEvent) { sendKey(event.keyCode, down: true) }
    public override func keyUp(with event: NSEvent) { sendKey(event.keyCode, down: false) }

    /// 让 Cmd 组合键也交给客户机，而不是触发菜单快捷键。
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    /// 修饰键只有 flagsChanged：按设备相关的左右键位判断按下还是松开；大写锁定每次变化都是一次完整按键。
    public override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == 0x39 {
            sendKey(code, down: true)
            sendKey(code, down: false)
            return
        }
        guard let mask = Self.modifierMasks[code] else { return }
        let down = event.modifierFlags.rawValue & mask != 0
        if down { pressedModifiers.insert(code) } else { pressedModifiers.remove(code) }
        sendKey(code, down: down)
    }

    /// 失去焦点时松开仍按着的修饰键，免得客户机里一直按着。
    public override func resignFirstResponder() -> Bool {
        for code in pressedModifiers { sendKey(code, down: false) }
        pressedModifiers.removeAll()
        return super.resignFirstResponder()
    }

    private func sendKey(_ keyCode: UInt16, down: Bool) {
        guard let scancode = Self.scancodes[keyCode] else { return }
        client?.sendKey(scancode: scancode, down: down)
    }

    /// NSEvent 设备相关修饰键位（IOKit 的 NX_DEVICE*KEYMASK）。
    private static let modifierMasks: [UInt16: UInt] = [
        0x38: 0x02, 0x3c: 0x04, // Shift 左、右
        0x3b: 0x01, 0x3e: 0x2000, // Control
        0x3a: 0x20, 0x3d: 0x40, // Option
        0x37: 0x08, 0x36: 0x10, // Command
    ]

    /// macOS 虚拟键码到 PC 扫描码（第 1 套）；带 E0 前缀的键为 0x80 | 第二字节，即 QEMU 的 qnum。
    /// Command 映射为 Windows 键。
    private static let scancodes: [UInt16: UInt32] = [
        0x00: 0x1e, 0x01: 0x1f, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2c, 0x07: 0x2d,
        0x08: 0x2e, 0x09: 0x2f, 0x0a: 0x56, 0x0b: 0x30, 0x0c: 0x10, 0x0d: 0x11, 0x0e: 0x12, 0x0f: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0d, 0x19: 0x0a, 0x1a: 0x08, 0x1b: 0x0c, 0x1c: 0x09, 0x1d: 0x0b, 0x1e: 0x1b, 0x1f: 0x18,
        0x20: 0x16, 0x21: 0x1a, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1c, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2a: 0x2b, 0x2b: 0x33, 0x2c: 0x35, 0x2d: 0x31, 0x2e: 0x32, 0x2f: 0x34,
        0x30: 0x0f, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0e, 0x35: 0x01,
        0x36: 0xdc, 0x37: 0xdb, 0x38: 0x2a, 0x39: 0x3a, 0x3a: 0x38, 0x3b: 0x1d, 0x3c: 0x36, 0x3d: 0xb8, 0x3e: 0x9d,
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4e, 0x47: 0x45, 0x4b: 0xb5, 0x4c: 0x9c, 0x4e: 0x4a, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4f, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4b, 0x57: 0x4c, 0x58: 0x4d, 0x59: 0x47,
        0x5b: 0x48, 0x5c: 0x49, 0x5d: 0x7d, 0x5e: 0x73, 0x66: 0x7b, 0x68: 0x79,
        0x60: 0x3f, 0x61: 0x40, 0x62: 0x41, 0x63: 0x3d, 0x64: 0x42, 0x65: 0x43, 0x67: 0x57, 0x6d: 0x44,
        0x6f: 0x58, 0x76: 0x3e, 0x78: 0x3c, 0x7a: 0x3b,
        0x72: 0xd2, 0x73: 0xc7, 0x74: 0xc9, 0x75: 0xd3, 0x77: 0xcf, 0x79: 0xd1,
        0x7b: 0xcb, 0x7c: 0xcd, 0x7d: 0xd0, 0x7e: 0xc8,
    ]
}
