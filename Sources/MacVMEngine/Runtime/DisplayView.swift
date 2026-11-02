public import AppKit
@preconcurrency import Virtualization

extension VMRunner {
    /// 显示本虚拟机画面并接收键鼠的视图。窗口缩放时客户机跟着改分辨率，而不是缩放画面。
    public func makeDisplayView() -> NSView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        return view
    }

    /// 断开视图只停止画面传输，虚拟机继续运行，重新创建视图即可接上。
    public static func detachDisplayView(_ view: NSView) {
        (view as? VZVirtualMachineView)?.virtualMachine = nil
    }
}
