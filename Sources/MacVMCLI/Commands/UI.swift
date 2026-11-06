public import ArgumentParser
import Foundation
public import MacVMEngine
import MacVMModel

extension AgentProtocol.ElementAction: ExpressibleByArgument {}
extension AgentProtocol.MouseButton: ExpressibleByArgument {}

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: String(l10n: "Read and control the guest desktop through the guest agent."),
        discussion: String(l10n: """
        snapshot lists the accessibility tree of the frontmost app, or of the app given with --app. Each element gets a number you can pass to act and click --element; the numbers stay valid until the next snapshot.
        Coordinates are always pixels in the ui screenshot image, measured from the top-left corner of the main screen.
        On macOS guests, MacVM Agent needs Accessibility and Screen Recording permission in System Settings › Privacy & Security, or commands fail with permission_denied. Linux guests need a logged-in graphical session.
        """),
        subcommands: [Snapshot.self, Act.self, Click.self, Move.self, Drag.self, Scroll.self, TypeText.self, Key.self, Shot.self]
    )

    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "List an app's accessibility tree."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Option(help: ArgumentHelp(String(l10n: "App to inspect: pid, process name, or (on macOS) bundle ID. Defaults to the frontmost app."))) var app: String?
        @Option(help: ArgumentHelp(String(l10n: "Maximum tree depth."))) var depth: Int?
        @Option(help: ArgumentHelp(String(l10n: "Maximum number of elements."))) var limit: Int?

        func validate() throws {
            if let depth, depth < 0 { throw ValidationError(String(l10n: "--depth can't be negative")) }
            if let limit, limit < 0 { throw ValidationError(String(l10n: "--limit can't be negative")) }
        }

        func run() async throws {
            try await Output.run(json: global.json, human: Self.render) {
                try GuestUI.snapshot(VMLibrary.default.bundle(named: name), app: app, maxDepth: depth, maxNodes: limit)
            }
        }

        static func render(_ s: AgentProtocol.UISnapshot) -> String {
            let scale = s.screen.scale == 1 ? "" : " @\(String(format: "%g", s.screen.scale))x"
            var lines = [String(l10n: "Screen \(s.screen.width)×\(s.screen.height)\(scale)")]
            let apps = s.apps.map { "\($0.name) (\($0.pid))\($0.frontmost ? " *" : "")" }
            if !apps.isEmpty { lines.append(String(l10n: "Apps: \(apps.joinedAsList())")) }
            guard let app = s.app else { return (lines + [String(l10n: "No frontmost app")]).joined(separator: "\n") }
            lines.append("\(app.name) (pid \(app.pid))")
            lines += s.nodes.map(line)
            if s.truncated { lines.append(String(l10n: "…Stopped at the depth or element limit; raise it with --depth or --limit")) }
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
        static let configuration = CommandConfiguration(abstract: String(l10n: "Perform an action on an element from a snapshot."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument(help: ArgumentHelp(String(l10n: "Element number (from ui snapshot)."))) var element: String
        @Argument(help: ArgumentHelp(String(l10n: "Action: \(AgentProtocol.ElementAction.allCases.map(\.rawValue).joinedAsList())."))) var action: AgentProtocol.ElementAction
        @Option(help: ArgumentHelp(String(l10n: "Value for set-value."))) var value: String?

        func validate() throws {
            if action == .setValue, value == nil { throw ValidationError(String(l10n: "set-value requires --value")) }
        }

        func run() async throws {
            try await Output.run(json: global.json, human: { (_: Empty) in nil }) {
                try GuestUI.act(VMLibrary.default.bundle(named: name), element: element, action: action, value: value)
                return Empty()
            }
        }
    }

    struct Click: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Click a point or the center of an element."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument(help: ArgumentHelp(String(l10n: "x and y in screenshot pixels; omit when using --element."))) var point: [Int] = []
        @Option(help: ArgumentHelp(String(l10n: "Click the center of this element."))) var element: String?
        @Option(help: ArgumentHelp(String(l10n: "Mouse button: left, right, or middle."))) var button: AgentProtocol.MouseButton = .left
        @Option(help: ArgumentHelp(String(l10n: "Number of clicks."))) var count = 1

        func validate() throws {
            guard point.isEmpty ? element != nil : point.count == 2 && element == nil else {
                throw ValidationError(String(l10n: "Give either x and y coordinates or --element, not both"))
            }
            guard count >= 1 else { throw ValidationError(String(l10n: "--count must be at least 1")) }
        }

        func run() async throws {
            let event = AgentProtocol.InputEvent.click(x: point.first, y: point.last, element: element, button: button, count: count)
            try await send(event, to: name, json: global.json)
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Move the mouse."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument var x: Int
        @Argument var y: Int

        func run() async throws { try await send(.move(x: x, y: y), to: name, json: global.json) }
    }

    struct Drag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Drag from one point to another with a mouse button held down."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument var x1: Int
        @Argument var y1: Int
        @Argument var x2: Int
        @Argument var y2: Int
        @Option(help: ArgumentHelp(String(l10n: "Mouse button: left, right, or middle."))) var button: AgentProtocol.MouseButton = .left

        func run() async throws { try await send(.drag(from: [x1, y1], to: [x2, y2], button: button), to: name, json: global.json) }
    }

    struct Scroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: String(l10n: "Scroll at a point."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument var x: Int
        @Argument var y: Int
        @Option(parsing: .unconditional, help: ArgumentHelp(String(l10n: "Horizontal scroll steps; positive values scroll right."))) var dx = 0
        @Option(parsing: .unconditional, help: ArgumentHelp(String(l10n: "Vertical scroll steps; positive values scroll down."))) var dy = 0

        func run() async throws { try await send(.scroll(x: x, y: y, dx: dx, dy: dy), to: name, json: global.json) }
    }

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: String(l10n: "Type text into the focused element."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument(help: ArgumentHelp(String(l10n: "Text to type."))) var text: String

        func run() async throws { try await send(.text(text), to: name, json: global.json) }
    }

    struct Key: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: String(l10n: "Press a key combination."),
            discussion: String(l10n: "For example: enter, cmd+shift+t, ctrl+alt+delete. Modifiers are cmd (the Windows key on Windows, Super on Linux), ctrl, alt (option), and shift. The main key is a key name, or the character the key types without Shift, on a US keyboard.")
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument(help: ArgumentHelp(String(l10n: "Key combination."))) var keys: String

        func run() async throws { try await send(.key(keys), to: name, json: global.json) }
    }

    struct Shot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "screenshot", abstract: String(l10n: "Capture the guest's main screen as a PNG."))
        @OptionGroup var global: GlobalOptions
        @Argument(help: ArgumentHelp(String(l10n: "VM name."))) var name: String
        @Argument(help: ArgumentHelp(String(l10n: "Path to save the PNG to."))) var output: String

        struct Result: Encodable, Sendable {
            let path: String
            let width: Int
            let height: Int
        }

        func run() async throws {
            try await Output.run(json: global.json, human: { (r: Result) in "\(r.path) (\(r.width)×\(r.height))" }) {
                let png = try GuestUI.screenshot(VMLibrary.default.bundle(named: name))
                let url = URL(filePath: (output as NSString).expandingTildeInPath).standardizedFileURL
                do {
                    try png.write(to: url)
                } catch {
                    throw MacVMError.io(String(l10n: "Couldn't write \(url.path): \(error.localizedDescription)"))
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
