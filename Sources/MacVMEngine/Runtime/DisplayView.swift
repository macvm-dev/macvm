public import AppKit
@preconcurrency import Virtualization

extension VZRunner {
    /// 显示本虚拟机画面并接收键鼠的视图。窗口缩放时客户机跟着改分辨率，而不是缩放画面。
    /// Windows 的显示驱动不会跟随输出尺寸切换分辨率，要经 `resizeDisplay` 由代理切换，所以不用 VZ 的自动重配。
    public func makeDisplayView() -> NSView {
        let view = ResizingDisplayView()
        view.capturesSystemKeys = true
        if config.os == .windows {
            view.onResize = { [weak self] pixels, points in
                // 超出驱动能切换的尺寸时（大窗口、Retina 屏）按点数而不是像素设定分辨率。
                let size = WindowsSupport.fitsDisplay(width: Int(pixels.width), height: Int(pixels.height)) ? pixels : points
                try? self?.resizeDisplay(width: Int(size.width), height: Int(size.height))
            }
        } else {
            view.automaticallyReconfiguresDisplay = true
        }
        view.virtualMachine = virtualMachine
        return view
    }

    /// 断开视图只停止画面传输，虚拟机继续运行，重新创建视图即可接上。
    public static func detachDisplayView(_ view: NSView) {
        (view as? VZVirtualMachineView)?.virtualMachine = nil
    }
}

/// 尺寸或屏幕缩放比变化时报告视图的像素尺寸与点数尺寸。
private final class ResizingDisplayView: VZVirtualMachineView {
    var onResize: ((_ pixels: CGSize, _ points: CGSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    private func reportSize() {
        guard let onResize, window != nil, bounds.width >= 1, bounds.height >= 1 else { return }
        onResize(convertToBacking(bounds).size, bounds.size)
    }
}
