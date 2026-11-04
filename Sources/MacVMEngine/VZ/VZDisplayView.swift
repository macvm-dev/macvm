public import AppKit
@preconcurrency import Virtualization

extension VZRunner {
    /// 显示本虚拟机画面并接收键鼠的视图。窗口缩放时客户机跟着改分辨率，而不是缩放画面；
    /// VZ 下的 Windows 分辨率固定（`WindowsSupport.displaySize`），画面按比例缩放。
    public func makeDisplayView() -> NSView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = config.os != .windows
        view.virtualMachine = virtualMachine
        return view
    }

    /// 断开视图只停止画面传输，虚拟机继续运行，重新创建视图即可接上。
    public static func detachDisplayView(_ view: NSView) {
        (view as? VZVirtualMachineView)?.virtualMachine = nil
    }

    /// 等到 `makeDisplayView` 的视图收到客户机的第一帧；在那之前视图里没有内容，显示为黑屏。
    /// VZ 没有帧到达的回调，这里轮询视图的层里是否已有内容。返回是否等到：
    /// 视图断开虚拟机、任务取消或过了 `firstFrameTimeout` 都返回 false。
    public static func waitForFirstFrame(in view: NSView) async -> Bool {
        let deadline = ContinuousClock.now + firstFrameTimeout
        while !Task.isCancelled, (view as? VZVirtualMachineView)?.virtualMachine != nil, ContinuousClock.now < deadline {
            if hasContents(view.layer) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 层树里的结构不是公开接口，认不出第一帧时等到这么久就放弃。
    private static let firstFrameTimeout: Duration = .seconds(30)

    private static func hasContents(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return layer.contents != nil || (layer.sublayers ?? []).contains { hasContents($0) }
    }
}
