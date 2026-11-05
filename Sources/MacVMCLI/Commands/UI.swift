public import ArgumentParser
import Foundation
public import MacVMEngine
import MacVMModel

extension AgentProtocol.ElementAction: ExpressibleByArgument {}
extension AgentProtocol.MouseButton: ExpressibleByArgument {}

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "经客户机代理读取与操作客户机桌面。",
        discussion: """
        snapshot 列出前台应用（或 --app 指定的应用）的无障碍树，每个元素有一个编号，act 与 click --element 用它，下一次 snapshot 后作废。
        坐标一律是 ui screenshot 截图的像素，原点在主屏左上角。macOS 客户机要在「系统设置 › 隐私与安全性」里给 MacVM Agent
        辅助功能与屏幕录制权限，没给时报 permission_denied；Linux 客户机要有已登录的图形会话。
        """,
        subcommands: [Snapshot.self, Act.self, Click.self, Move.self, Drag.self, Scroll.self, TypeText.self, Key.self, Shot.self]
    )

    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出应用的无障碍树。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Option(help: "应用：pid、进程名，macOS 上也可以是 bundle id；缺省为前台应用。") var app: String?
        @Option(help: "遍历深度上限。") var depth: Int?
        @Option(help: "元素个数上限。") var limit: Int?

        func validate() throws {
            if let depth, depth < 0 { throw ValidationError("--depth 不能为负数") }
            if let limit, limit < 0 { throw ValidationError("--limit 不能为负数") }
        }

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try GuestUI.snapshot(VMLibrary.default.bundle(named: name), app: app, maxDepth: depth, maxNodes: limit)
            }
        }

        static func render(_ s: AgentProtocol.UISnapshot) -> String {
            let scale = s.screen.scale == 1 ? "" : " @\(String(format: "%g", s.screen.scale))x"
            var lines = ["屏幕 \(s.screen.width)×\(s.screen.height)\(scale)"]
            let apps = s.apps.map { "\($0.name)（\($0.pid)）\($0.frontmost ? " *" : "")" }
            if !apps.isEmpty { lines.append("应用：" + apps.joined(separator: "，")) }
            guard let app = s.app else { return (lines + ["没有前台应用"]).joined(separator: "\n") }
            lines.append("\(app.name)（pid \(app.pid)）")
            lines += s.nodes.map(line)
            if s.truncated { lines.append("…已达深度或个数上限，用 --depth、--limit 放宽") }
            return lines.joined(separator: "\n")
        }

        static func line(_ n: AgentProtocol.UINode) -> String {
            var parts = ["[\(n.id)]", n.subrole.map { "\(n.role):\($0)" } ?? n.role]
            if let name = n.name { parts.append(quoted(name)) }
            if let value = n.value { parts.append("= " + quoted(value)) }
            if let b = n.bounds, b.count == 4 { parts.append("(\(b[0]),\(b[1]) \(b[2])×\(b[3]))") }
            if !n.states.isEmpty { parts.append(n.states.joined(separator: ",")) }
            if !n.actions.isEmpty { parts.append("· " + n.actions.joined(separator: " ")) }
            return String(repeating: "  ", count: n.depth) + parts.joined(separator: " ")
        }

        /// 单行显示：换行转义，过长截断。
        private static func quoted(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: "\\n")
            return "\"" + (flat.count > 80 ? flat.prefix(80) + "…" : flat) + "\""
        }
    }

    struct Act: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "对快照里的元素执行动作。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument(help: "元素编号（来自 ui snapshot）。") var element: String
        @Argument(help: "动作：\(AgentProtocol.ElementAction.allCases.map(\.rawValue).joined(separator: "、"))。") var action: AgentProtocol.ElementAction
        @Option(help: "set-value 要设的值。") var value: String?

        func validate() throws {
            if action == .setValue, value == nil { throw ValidationError("set-value 需要 --value") }
        }

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in nil }) {
                try GuestUI.act(VMLibrary.default.bundle(named: name), element: element, action: action, value: value)
                return Empty()
            }
        }
    }

    struct Click: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "在坐标或元素中心点击。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument(help: "x 与 y（截图像素）；给了 --element 时省略。") var point: [Int] = []
        @Option(help: "点这个元素的中心。") var element: String?
        @Option(help: "left、right 或 middle。") var button: AgentProtocol.MouseButton = .left
        @Option(help: "连击次数。") var count = 1

        func validate() throws {
            guard point.isEmpty ? element != nil : point.count == 2 && element == nil else {
                throw ValidationError("给出 x y 两个坐标，或者 --element，二选一")
            }
            guard count >= 1 else { throw ValidationError("--count 至少为 1") }
        }

        func run() async throws {
            let event = AgentProtocol.InputEvent.click(x: point.first, y: point.last, element: element, button: button, count: count)
            try await send(event, to: name, json: global.json)
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "移动鼠标。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument var x: Int
        @Argument var y: Int

        func run() async throws { try await send(.move(x: x, y: y), to: name, json: global.json) }
    }

    struct Drag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "按住鼠标键从一点拖到另一点。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument var x1: Int
        @Argument var y1: Int
        @Argument var x2: Int
        @Argument var y2: Int
        @Option(help: "left、right 或 middle。") var button: AgentProtocol.MouseButton = .left

        func run() async throws { try await send(.drag(from: [x1, y1], to: [x2, y2], button: button), to: name, json: global.json) }
    }

    struct Scroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "在某点滚动滚轮。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument var x: Int
        @Argument var y: Int
        @Option(parsing: .unconditional, help: "水平格数，正值向右。") var dx = 0
        @Option(parsing: .unconditional, help: "竖直格数，正值向下。") var dy = 0

        func run() async throws { try await send(.scroll(x: x, y: y, dx: dx, dy: dy), to: name, json: global.json) }
    }

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "向焦点处输入文本。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument(help: "文本。") var text: String

        func run() async throws { try await send(.text(text), to: name, json: global.json) }
    }

    struct Key: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "按组合键。",
            discussion: "如 enter、cmd+shift+t、ctrl+alt+delete。修饰键 cmd（Windows 为 Win 键，Linux 为 Super）、ctrl、alt（option）、shift；主键是美式键盘上的键名或不按 Shift 时的字符。"
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument(help: "组合键。") var keys: String

        func run() async throws { try await send(.key(keys), to: name, json: global.json) }
    }

    struct Shot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "screenshot", abstract: "在客户机里截主屏，存为 PNG。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "虚拟机名称。") var name: String
        @Argument(help: "输出文件。") var output: String

        struct Result: Encodable, Sendable {
            let path: String
            let width: Int
            let height: Int
        }

        func run() async throws {
            try await Output.run(json: global.json, human: { (r: Result) in "\(r.path)（\(r.width)×\(r.height)）" }) {
                let png = try GuestUI.screenshot(VMLibrary.default.bundle(named: name))
                let url = URL(filePath: (output as NSString).expandingTildeInPath).standardizedFileURL
                do {
                    try png.write(to: url)
                } catch {
                    throw MacVMError.io("写入 \(url.path) 失败：\(error.localizedDescription)")
                }
                let (width, height) = Self.size(png)
                return Result(path: url.path, width: width, height: height)
            }
        }

        /// PNG 的 IHDR 里的宽高（大端，紧跟 8 字节签名与 8 字节块头）。
        static func size(_ png: Data) -> (Int, Int) {
            guard png.count >= 24 else { return (0, 0) }
            let be = { (at: Int) in png[png.startIndex + at..<png.startIndex + at + 4].reduce(0) { $0 << 8 | Int($1) } }
            return (be(16), be(20))
        }
    }

    static func send(_ event: AgentProtocol.InputEvent, to name: String, json: Bool) async throws {
        try await Output.run(json: json, human: { (_: Empty) in nil }) {
            try GuestUI.input(VMLibrary.default.bundle(named: name), [event])
            return Empty()
        }
    }
}
