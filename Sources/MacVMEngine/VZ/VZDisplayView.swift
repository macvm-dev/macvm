public import AppKit
@preconcurrency import Virtualization
import MacVMModel

extension VZRunner {
    /// 显示本虚拟机画面并接收键鼠的视图。窗口缩放时客户机跟着改分辨率，而不是缩放画面；
    /// VZ 下的 Windows 分辨率固定（`WindowsSupport.displaySize`），画面按比例缩放。
    public func makeDisplayView() -> NSView {
        let view = config.os == .linux ? LinuxDisplayView(bundle: bundle, config: config) : GuestDisplayView(bundle: bundle, config: config)
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = config.os == .macOS
        view.virtualMachine = virtualMachine
        if let view = view as? LinuxDisplayView { view.applyPreference() }
        return view
    }

    /// 断开视图只停止画面传输，虚拟机继续运行，重新创建视图即可接上。
    public static func detachDisplayView(_ view: NSView) {
        (view as? VZVirtualMachineView)?.virtualMachine = nil
    }

    /// 等到 `makeDisplayView` 的视图收到客户机的第一帧；在那之前视图里没有内容，显示为黑屏。
    /// VZ 没有帧到达的回调，这里轮询视图的层里是否已有内容。返回是否等到：
    /// 视图断开虚拟机、任务取消或过了 `timeout` 都返回 false。
    public static func waitForFirstFrame(in view: NSView, timeout: Duration = firstFrameTimeout) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled, (view as? VZVirtualMachineView)?.virtualMachine != nil, ContinuousClock.now < deadline {
            if hasContents(view.layer) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 层树里的结构不是公开接口，认不出第一帧时等到这么久就放弃。
    public static let firstFrameTimeout: Duration = .seconds(30)

    private static func hasContents(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return layer.contents != nil || (layer.sublayers ?? []).contains { hasContents($0) }
    }
}

/// 客户机画面，并与客户机互相拖放文件（`GuestFileDrag`）。
class GuestDisplayView: VZVirtualMachineView {
    private let fileDrag: GuestFileDrag
    /// 最近一次交给 VZ 的鼠标事件，取消客户机里的拖动时在同一位置抬起左键。
    private var lastMouseEvent: NSEvent?

    init(bundle: VMBundle, config: VMConfig) {
        fileDrag = GuestFileDrag(bundle: bundle, os: config.os, hasAgent: config.guestAgent)
        super.init(frame: .zero)
        registerForDraggedTypes(GuestFileDrag.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { fileDrag.draggingOperation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { fileDrag.draggingOperation(sender) }

    /// 投放点换算成视图宽、高的比例；画面按比例缩放留边时略有偏差，只影响落到哪个文件夹窗口。
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        let fraction = bounds.width > 0 && bounds.height > 0 ? CGPoint(x: p.x / bounds.width, y: 1 - p.y / bounds.height) : nil
        return fileDrag.performDrop(sender, at: fraction)
    }

    override func mouseDown(with event: NSEvent) {
        fileDrag.mouseDown()
        lastMouseEvent = event
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        fileDrag.mouseUp()
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let items = fileDrag.mouseDragged(outside: !bounds.contains(p), at: p) {
            beginDraggingSession(with: items, event: event, source: fileDrag)
            cancelGuestDrag()
            return
        }
        lastMouseEvent = event
        super.mouseDragged(with: event)
    }

    /// 宿主接手拖动后 VZ 收不到抬起：给客户机按一下 Esc 取消它那边的拖动，再在原处抬起左键。
    private func cancelGuestDrag() {
        guard let window, let last = lastMouseEvent else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let esc = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53) {
                type == .keyDown ? super.keyDown(with: esc) : super.keyUp(with: esc)
            }
        }
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: last.locationInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            super.mouseUp(with: up)
        }
    }
}

/// Linux 客户机的画面。VZ 自动调整时按屏幕像素设分辨率，客户机不知道宿主是 Retina，界面在 Retina 屏上只有一半大；
/// 没开 `DisplayConfig.retina` 时改为按窗口点数设分辨率，画面放大显示，两种屏上界面一样大；
/// 开了时经代理把客户机的缩放比例调到屏幕倍数，界面大小相同而更清晰。
final class LinuxDisplayView: GuestDisplayView {
    private let bundle: VMBundle
    private var fit: Timer?
    private var preferenceObserver: (any NSObjectProtocol)?
    /// 代理已接受的缩放比例；客户机重启后代理忘了它，但已写进用户设置，不必再发。
    private var sentScale: Int?
    private var hasAgent = false
    private var scaleRetry: Timer?
    /// 代理还没上线（客户机开机中）时隔这么久重试。
    private static let scaleRetryInterval: TimeInterval = 5
    /// 拖动窗口时每帧都在变，停下来这么久再改客户机分辨率。
    private static let fitDelay: TimeInterval = 0.3
    /// 客户机分辨率的下限（点数），再小桌面就排不开了。
    private static let minimumSize = CGSize(width: 800, height: 600)

    override init(bundle: VMBundle, config: VMConfig) {
        self.bundle = bundle
        super.init(bundle: bundle, config: config)
    }

    /// 按当前设置选择由 VZ 按像素自动调整，还是自己按点数调整。
    func applyPreference() {
        let config = try? bundle.loadConfig()
        let retina = config?.display.retina == true
        automaticallyReconfiguresDisplay = retina
        if !retina { scheduleFit(after: 0) }
        hasAgent = config?.guestAgent == true
        sendScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sendScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sendScale()
    }

    /// 开了 `DisplayConfig.retina` 时为屏幕倍数，否则 100。
    private var wantedScale: Int {
        automaticallyReconfiguresDisplay ? Int(((window?.backingScaleFactor ?? 1) * 100).rounded()) : 100
    }

    /// 探测代理是阻塞的 socket 往返，运行器的控制 socket 由主 actor 应答，所以在后台线程上发。
    /// 只在连不上代理时重试；代理回了错误（不支持这个请求）就不再发。
    private func sendScale() {
        scaleRetry?.invalidate()
        scaleRetry = nil
        guard hasAgent, window != nil else { return }
        let percent = wantedScale
        guard sentScale != percent else { return }
        let bundle = bundle
        Task { [weak self] in
            let answered = await Task.detached { (try? AgentClient.open(.displayScale(percent: percent), bundle: bundle, timeout: 10)) != nil }.value
            guard let self, wantedScale == percent else { return }
            if answered {
                sentScale = percent
            } else {
                scaleRetry = Timer.scheduledTimer(withTimeInterval: Self.scaleRetryInterval, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendScale() }
                }
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !automaticallyReconfiguresDisplay { scheduleFit(after: Self.fitDelay) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        guard newWindow != nil else {
            fit?.invalidate()
            scaleRetry?.invalidate()
            return
        }
        preferenceObserver = DisplayPreference.observe(bundle.name) { [weak self] in self?.applyPreference() }
    }

    private func scheduleFit(after delay: TimeInterval) {
        fit?.invalidate()
        fit = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitGuestToView() }
        }
    }

    private func fitGuestToView() {
        guard !automaticallyReconfiguresDisplay, window != nil,
              let display = virtualMachine?.graphicsDevices.first?.displays.first else { return }
        // 偶数宽高，部分驱动要求宽度对齐。
        let size = CGSize(width: max(Int(bounds.width) & ~1, Int(Self.minimumSize.width)),
                          height: max(Int(bounds.height) & ~1, Int(Self.minimumSize.height)))
        guard display.sizeInPixels != size else { return }
        try? display.reconfigure(sizeInPixels: size)
    }
}
