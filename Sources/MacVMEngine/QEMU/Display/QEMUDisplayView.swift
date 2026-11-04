public import AppKit
public import MacVMModel

/// 显示 QEMU 虚拟机画面并转发键鼠的视图：虚拟机提供 SPICE（`QEMUCommand.spiceSocket`）且有显示库时用 SPICE，
/// 否则连 `QEMUCommand.vncSocket` 上的 VNC。不要求虚拟机在本进程运行：`macvm start` 在后台运行的虚拟机同样能显示。
/// 用 SPICE 时窗口大小停下来后请客户机把分辨率改成窗口大小（点数），客户机不跟随时画面按比例缩放进视图。
/// 光标形状优先取客户机代理推送的（`AgentCursorWatcher`），
/// 用作宿主光标，跟手且无延迟；viogpudo 上传形状与切换光标之间没有同步，VNC 收到的常是上一个形状。
/// 代理不推送时用客户机的硬件光标形状（VNC 转来的，或 SPICE 光标通道的）；SPICE 收不到形状时把光标画进画面，
/// 客户机自己画光标时宿主光标隐藏。
public final class QEMUDisplayView: NSView {
    private let bundle: VMBundle
    private let vncPath: String
    private let spicePath: String
    private var backend: (any DisplayBackend)?
    private var spice: SpiceDisplay? { backend as? SpiceDisplay }
    private var cursorWatcher: AgentCursorWatcher?
    private var cursorWatchRetry: Timer?
    /// 代理正在推送光标形状，此时忽略 VNC 与 SPICE 的光标。
    private var agentCursorActive = false
    /// 当前 SPICE 连接最近送来的客户机光标；有它时宿主光标用它，光标不再画进画面。
    private var spiceCursor: GuestCursor?
    private var framebufferSize = CGSize.zero
    private var reconnect: Timer?
    private var buttons: UInt8 = 0
    private var scrollAccumulator: CGFloat = 0
    private var pressedModifiers: Set<UInt16> = []

    public init(bundle: VMBundle) {
        self.bundle = bundle
        vncPath = QEMUCommand.vncSocket(bundle).path
        spicePath = QEMUCommand.spiceSocket(bundle).path
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
        backend?.close()
        backend = nil
        guestFit?.invalidate()
        guestFit = nil
        requestedGuestSize = nil
        requestedGuestScale = nil
        endScaleTransition()
        cursorWatchRetry?.invalidate()
        cursorWatchRetry = nil
        cursorWatcher?.onClose = nil
        cursorWatcher?.close()
        cursorWatcher = nil
        agentCursorActive = false
        spiceCursor = nil
    }

    private func connect() {
        guard backend == nil else { return }
        if let library = Self.displayLibrary, let spice = SpiceDisplay(socketPath: spicePath, library: library) {
            spice.onResize = { [weak self] size in
                guard let self else { return }
                let resized = framebufferSize != size
                framebufferSize = size
                if resized { rebuildGuestCursor() }
                if let transition = scaleTransition, !transition.scaleSent, transition.size == (Int(size.width), Int(size.height)) {
                    sendTransitionScale()
                }
            }
            spice.onClose = { [weak self] in
                guard let self else { return }
                spiceCursor = nil
                backend?.close()
                backend = nil
                scheduleReconnect()
            }
            spice.onConnect = { [weak self] in
                self?.requestedGuestSize = nil
                self?.scheduleGuestFit()
            }
            spice.onCursor = { [weak self] cursor in
                guard let self else { return }
                if spiceCursor == nil, !agentCursorActive { self.spice?.showGuestCursor(false) }
                spiceCursor = cursor
                if !agentCursorActive { setGuestCursor(cursor) }
            }
            spice.view.frame = bounds
            spice.view.autoresizingMask = [.width, .height]
            addSubview(spice.view)
            spice.showGuestCursor(!agentCursorActive)
            backend = spice
            watchAgentCursor()
            return
        }
        do {
            let client = try VNCClient(path: vncPath)
            client.onFrame = { [weak self] image, size in
                guard let self else { return }
                let resized = framebufferSize != size
                framebufferSize = size
                layer?.contents = image
                if resized { rebuildGuestCursor() }
            }
            client.onCursor = { [weak self] image, hotspot in
                guard let self, !agentCursorActive else { return }
                setGuestCursor(image.map { .image($0, hotspot: hotspot) } ?? .hidden)
            }
            // 断开后读线程才结束、回调随后才到，那时视图可能已换上新连接：只处理仍是当前连接的。
            client.onClose = { [weak self, weak client] in
                guard let self, let client, backend === client else { return }
                backend = nil
                scheduleReconnect()
            }
            backend = client
            client.start()
            watchAgentCursor()
        } catch {
            scheduleReconnect()
        }
    }

    /// 自带 QEMU 的显示库；没有时只能用 VNC。
    private static let displayLibrary = QEMUInstallation.locate()?.displayLibrary

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

    /// 代理未就绪（客户机还在开机）或连接断开时过一会儿重试；代理明确不提供时不再重试，直到画面重连。
    private func watchAgentCursor() {
        guard cursorWatcher == nil, cursorWatchRetry == nil, window != nil else { return }
        let watcher = AgentCursorWatcher(bundle: bundle)
        watcher.onShape = { [weak self] cursor in
            guard let self else { return }
            if !agentCursorActive {
                spice?.showGuestCursor(false)
                agentCameOnline()
            }
            agentCursorActive = true
            arrowUntilAgentReturns = false
            setGuestCursor(cursor)
        }
        watcher.onClose = { [weak self] retry in
            guard let self else { return }
            cursorWatcher = nil
            // 推送中断时代理可能已经退出，客户机里的系统光标还是透明的，先用箭头顶上，直到代理重新推送或明确不推。
            arrowUntilAgentReturns = retry && (agentCursorActive || arrowUntilAgentReturns)
            if agentCursorActive {
                agentCursorActive = false
                guestCursorImage = nil
                guestSystemCursor = nil
                guestCursor = nil
                if let spiceCursor { setGuestCursor(spiceCursor) }
            }
            updateCursor()
            spice?.showGuestCursor(spiceCursor == nil)
            guard retry, window != nil else {
                // 代理在线但不提供光标（客户机自己画光标）。
                agentCameOnline()
                return
            }
            cursorWatchRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cursorWatchRetry = nil
                    self?.watchAgentCursor()
                }
            }
        }
        cursorWatcher = watcher
        watcher.start()
    }

    /// 代理（重新）上线：客户机可能刚开机或重启过，画面连接没断但分辨率与缩放比例可能已回到开机时的值，重新核对一遍。
    private func agentCameOnline() {
        requestedGuestSize = nil
        requestedGuestScale = nil
        scheduleGuestFit()
    }

    /// 指针在视图里且窗口在前台时：有客户机光标形状就设为宿主光标，否则隐藏宿主光标（客户机自己画），免得出现两个。
    /// `NSCursor.hide` 按次数计、作用于整个应用，所以只在状态变化时调用一次并在离开、失焦、移除时恢复。
    private var cursorHidden = false
    private var keyObservers: [any NSObjectProtocol] = []
    private var guestCursorImage: (image: CGImage, hotspot: CGPoint)?
    private var guestSystemCursor: NSCursor?
    private var guestCursor: NSCursor?
    /// 客户机隐藏了光标（如全屏视频、输入时）。
    private var guestCursorHidden = false
    private var arrowUntilAgentReturns = false

    private func setGuestCursor(_ cursor: GuestCursor) {
        switch cursor {
        case .hidden:
            guestCursorHidden = true
        case let .image(image, hotspot):
            guestCursorImage = (image, hotspot)
            guestSystemCursor = nil
            guestCursorHidden = false
        case let .system(kind):
            guestSystemCursor = Self.nativeCursor(kind)
            guestCursorImage = nil
            guestCursorHidden = false
        }
        rebuildGuestCursor()
    }

    /// 客户机系统光标的种类对应的 macOS 光标；macOS 没有同类光标的用箭头。
    static func nativeCursor(_ kind: String) -> NSCursor {
        switch kind {
        case "ibeam": .iBeam
        case "hand": .pointingHand
        case "crosshair": .crosshair
        case "no": .operationNotAllowed
        case "sizewe": .frameResize(position: .left, directions: .all)
        case "sizens": .frameResize(position: .top, directions: .all)
        case "sizenwse": .frameResize(position: .topLeft, directions: .all)
        case "sizenesw": .frameResize(position: .topRight, directions: .all)
        case "sizeall": .openHand
        default: .arrow
        }
    }

    /// 图像光标按画面的缩放比例显示，与客户机里看到的大小一致。
    private func rebuildGuestCursor() {
        if let guestSystemCursor {
            guestCursor = guestSystemCursor
            updateCursor()
            return
        }
        guard let (image, hotspot) = guestCursorImage else { return }
        let scale = displayScale
        guestCursorScale = scale
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guestCursor = NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: NSPoint(x: hotspot.x * scale, y: hotspot.y * scale))
        updateCursor()
    }

    /// 图像光标按这个缩放比例建成；视图尺寸变了而比例没变时不必重建。
    private var guestCursorScale: CGFloat?

    private var displayScale: CGFloat {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return 1 }
        return min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
    }

    private func updateCursor() {
        let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        let active = inside && window?.isKeyWindow == true
        let arrow = guestCursor == nil && arrowUntilAgentReturns
        let hide = active && !arrow && (guestCursor == nil || guestCursorHidden)
        if hide != cursorHidden {
            cursorHidden = hide
            if hide { NSCursor.hide() } else { NSCursor.unhide() }
        }
        if active, !hide { (arrow ? NSCursor.arrow : guestCursor)?.set() }
    }

    public override func cursorUpdate(with event: NSEvent) {
        if let guestCursor, !guestCursorHidden { guestCursor.set() } else { super.cursorUpdate(with: event) }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if guestCursorImage != nil, displayScale != guestCursorScale { rebuildGuestCursor() }
        scheduleGuestFit()
    }

    // MARK: - 分辨率跟随窗口

    private var guestFit: Timer?
    private var requestedGuestSize: (Int, Int)?
    private var requestedGuestScale: Int?
    private var preferenceObserver: (any NSObjectProtocol)?
    /// 拖动窗口时每帧都在变，停下来这么久再请客户机切换。
    private static let guestFitDelay: TimeInterval = 0.4
    /// 客户机显示的最小尺寸（点数），再小 Windows 的界面就排不开了。
    private static let minimumGuestSize = (width: 800, height: 600)

    private func scheduleGuestFit(after delay: TimeInterval = guestFitDelay) {
        guard spice != nil else { return }
        guestFit?.invalidate()
        guestFit = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitGuestToView() }
        }
    }

    /// 经控制通道请运行这台虚拟机的进程转告 QEMU；虚拟机可能在别的进程里运行（`macvm start`）。
    /// 开了 `DisplayConfig.retina` 时按屏幕像素请求，再经代理把客户机的缩放比例调到屏幕倍数，界面大小与点数模式相同。
    private func fitGuestToView() {
        guard spice != nil, let window else { return }
        let config = try? bundle.loadConfig()
        let factor = config?.display.retina == true ? window.backingScaleFactor : 1
        // 偶数宽高，部分驱动要求宽度对齐。
        let (width, height) = QEMUCommand.fittingEDID((max(Int(bounds.width * factor) & ~1, Int(CGFloat(Self.minimumGuestSize.width) * factor)),
                                                       max(Int(bounds.height * factor) & ~1, Int(CGFloat(Self.minimumGuestSize.height) * factor))))
        let bundle = bundle
        if requestedGuestSize.map({ $0 != (width, height) }) ?? true {
            requestedGuestSize = (width, height)
            // 客户机已是这个尺寸（画面重连、客户机重启后沿用了原来的模式）就不发：同样的模式重设一遍画面也会黑一下。
            if (Int(framebufferSize.width), Int(framebufferSize.height)) != (width, height) {
                Task.detached { _ = try? ControlClient.send(.display(width: width, height: height), to: bundle, timeout: 5) }
            }
        }
        let percent = Int((factor * 100).rounded())
        guard config?.guestAgent == true, requestedGuestScale != percent else { return }
        let changing = requestedGuestScale != nil
        requestedGuestScale = percent
        guard changing, (Int(framebufferSize.width), Int(framebufferSize.height)) != (width, height) else {
            sendGuestScale(percent) { _ in }
            return
        }
        // 分辨率与缩放比例在客户机里先后生效，中间那一刻界面会突然缩小或放大。分辨率切换较慢，
        // 期间画面照常；新分辨率的第一帧到达时画面停住，再改缩放比例，客户机按新比例重绘完再放开。
        scaleTransition = ((width, height), percent, false)
        spice?.freezeOnResize()
        scheduleScaleTransitionEnd(after: Self.scaleTransitionTimeout)
    }

    private func sendGuestScale(_ percent: Int, then done: @escaping @MainActor (Bool) -> Void) {
        let bundle = bundle
        Task.detached { [weak self] in
            let ok = (try? AgentClient.call(.displayScale(percent: percent), bundle: bundle, timeout: 10)) != nil
            await MainActor.run {
                guard let self else { return }
                // 代理还没上线：等它上线或下次窗口变化时再试。
                if !ok, self.requestedGuestScale == percent { self.requestedGuestScale = nil }
                done(ok)
            }
        }
    }

    /// 缩放比例随分辨率一起变化的过渡：分辨率生效后才发缩放比例，其间画面冻结；客户机迟迟不切换时到期也照发、放开。
    private var scaleTransition: (size: (Int, Int), percent: Int, scaleSent: Bool)?
    private var scaleTransitionTimer: Timer?
    /// 缩放比例生效后，客户机连续这么久没有新帧即视为重绘完毕；一直有新帧（如有动画）时最多等 `guestRedrawLimit`。
    private static let guestRedrawIdle: TimeInterval = 0.25
    private static let guestRedrawLimit: TimeInterval = 1.5
    private static let scaleTransitionTimeout: TimeInterval = 3

    private func sendTransitionScale() {
        guard let transition = scaleTransition, !transition.scaleSent else { return }
        scaleTransition?.scaleSent = true
        scheduleScaleTransitionEnd(after: Self.scaleTransitionTimeout)
        sendGuestScale(transition.percent) { [weak self] _ in
            self?.finishScaleTransition()
        }
    }

    /// 客户机按新比例重绘桌面时中途会出整屏黑的帧，等它画完再放开画面。
    private func finishScaleTransition() {
        scaleTransitionTimer?.invalidate()
        scaleTransitionTimer = nil
        guard scaleTransition != nil else { return }
        scaleTransition = nil
        spice?.thawWhenIdle(idle: Self.guestRedrawIdle, limit: Self.guestRedrawLimit)
    }

    private func scheduleScaleTransitionEnd(after delay: TimeInterval) {
        scaleTransitionTimer?.invalidate()
        scaleTransitionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endScaleTransition() }
        }
    }

    private func endScaleTransition() {
        scaleTransitionTimer?.invalidate()
        scaleTransitionTimer = nil
        guard let transition = scaleTransition else { return }
        if !transition.scaleSent {
            sendTransitionScale()
            return
        }
        scaleTransition = nil
        spice?.setFrozen(false)
    }

    /// 换屏不像拖动改大小那样连续变化，不必等。
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleGuestFit(after: 0)
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
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        guard let newWindow else { return }
        preferenceObserver = DisplayPreference.observe(bundle.name) { [weak self] in self?.scheduleGuestFit() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCursor() }
            })
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
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

    private func sendPointer(_ event: NSEvent) {
        guard let (x, y) = framebufferPoint(event) else { return }
        backend?.sendPointer(buttons: buttons, x: x, y: y)
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

    /// 触控板的连续滚动累计到一格再发。
    public override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulator += event.scrollingDeltaY
        guard let (x, y) = framebufferPoint(event) else { return }
        while abs(scrollAccumulator) >= step {
            backend?.scroll(up: scrollAccumulator > 0, buttons: buttons, x: x, y: y)
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
        backend?.sendKey(qnum: scancode, down: down)
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
