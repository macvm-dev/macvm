import AppKit
import SwiftUI

/// 放进滚动内容里，把所在的 `NSScrollView` 固定为浮层滚动条（细、只在滚动时出现）。
/// 接了鼠标时系统改用常驻滚动条，灰底轨道贴在分组表单边上很突兀。
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                return
            }
            apply()
            guard observer == nil else { return }
            // 偏好变了 NSScrollView 会按新偏好改回去，等它改完再覆盖。
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }
    }
}
