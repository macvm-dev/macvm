import AppKit

/// App 图标的单色简化版：叠放的两个窗口；后台任务期间前窗里出现下载箭头或进度环。
@MainActor
enum MenuBarIcon {
    case idle
    case downloading
    case working

    var image: NSImage {
        switch self {
        case .idle: Self.idleImage
        case .downloading: Self.downloadingImage
        case .working: Self.workingImage
        }
    }

    var label: String {
        switch self {
        case .idle: "MacVM"
        case .downloading: "MacVM：正在下载"
        case .working: "MacVM：有任务进行中"
        }
    }

    private static let idleImage = draw(.idle)
    private static let downloadingImage = draw(.downloading)
    private static let workingImage = draw(.working)

    private static func draw(_ state: MenuBarIcon) -> NSImage {
        // 按点绘制并缓存模板，交给 AppKit 在各屏幕倍率下栅格化和着色。
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let window = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 14, height: 12),
                                      xRadius: 3, yRadius: 3)
            window.lineWidth = 1.5
            window.stroke()
            for x: CGFloat in [4.4, 6.8, 9.2] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.9, y: 12.9, width: 1.8, height: 1.8)).fill()
            }

            // 后窗只露出右边和下边，与前窗之间留出空隙。
            let back = NSBezierPath()
            back.lineWidth = 1.5
            back.lineCapStyle = .round
            back.move(to: NSPoint(x: 18.5, y: 12.5))
            back.line(to: NSPoint(x: 18.5, y: 4))
            back.appendArc(withCenter: NSPoint(x: 16, y: 4), radius: 2.5, startAngle: 0, endAngle: -90, clockwise: true)
            back.line(to: NSPoint(x: 5, y: 1.5))
            back.stroke()

            let mark = NSBezierPath()
            mark.lineWidth = 1.3
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            switch state {
            case .idle:
                break
            case .downloading:
                mark.move(to: NSPoint(x: 8.5, y: 11))
                mark.line(to: NSPoint(x: 8.5, y: 6.4))
                mark.move(to: NSPoint(x: 6.6, y: 8.3))
                mark.line(to: NSPoint(x: 8.5, y: 6.4))
                mark.line(to: NSPoint(x: 10.4, y: 8.3))
            case .working:
                let center = NSPoint(x: 8.5, y: 8.6)
                for start: CGFloat in [15, 135, 255] {
                    let radians = start * .pi / 180
                    mark.move(to: NSPoint(x: center.x + 2.3 * cos(radians), y: center.y + 2.3 * sin(radians)))
                    mark.appendArc(withCenter: center, radius: 2.3, startAngle: start, endAngle: start + 70, clockwise: false)
                }
            }
            mark.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
