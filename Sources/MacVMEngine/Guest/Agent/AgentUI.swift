import Foundation

/// `ui-*` 请求的参数与 `ui-snapshot` 的正文。坐标一律是客户机截图的像素，原点在主屏左上角。
extension AgentProtocol {
    /// 各系统无障碍动作归一后的名称。
    public enum ElementAction: String, Codable, Sendable, CaseIterable {
        case press, focus, toggle, expand, collapse, select, raise
        case setValue = "set-value"
        case scrollIntoView = "scroll-into-view"
        case showMenu = "show-menu"
    }

    public enum MouseButton: String, Codable, Sendable, CaseIterable {
        case left, right, middle
    }

    /// 输入事件。省略的字段按代理的默认值：左键、单击。
    public enum InputEvent: Codable, Sendable, Equatable {
        case move(x: Int, y: Int)
        /// 给 `element` 时点它的中心，否则点 (`x`, `y`)。
        case click(x: Int?, y: Int?, element: String?, button: MouseButton, count: Int)
        case drag(from: [Int], to: [Int], button: MouseButton)
        /// 单位是滚轮格；正值向右、向下。
        case scroll(x: Int, y: Int, dx: Int, dy: Int)
        /// 组合键，如 `cmd+shift+t`。
        case key(String)
        case text(String)

        private enum Keys: String, CodingKey { case type, x, y, element, button, count, from, to, dx, dy, keys, text }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .move(let x, let y):
                try c.encode("move", forKey: .type); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            case .click(let x, let y, let element, let button, let count):
                try c.encode("click", forKey: .type)
                try c.encodeIfPresent(x, forKey: .x); try c.encodeIfPresent(y, forKey: .y); try c.encodeIfPresent(element, forKey: .element)
                if button != .left { try c.encode(button, forKey: .button) }
                if count != 1 { try c.encode(count, forKey: .count) }
            case .drag(let from, let to, let button):
                try c.encode("drag", forKey: .type); try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
                if button != .left { try c.encode(button, forKey: .button) }
            case .scroll(let x, let y, let dx, let dy):
                try c.encode("scroll", forKey: .type); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
                try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
            case .key(let keys): try c.encode("key", forKey: .type); try c.encode(keys, forKey: .keys)
            case .text(let text): try c.encode("text", forKey: .type); try c.encode(text, forKey: .text)
            }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let button = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
            switch try c.decode(String.self, forKey: .type) {
            case "move": self = .move(x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
            case "click":
                self = .click(x: try c.decodeIfPresent(Int.self, forKey: .x), y: try c.decodeIfPresent(Int.self, forKey: .y),
                              element: try c.decodeIfPresent(String.self, forKey: .element), button: button,
                              count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
            case "drag": self = .drag(from: try c.decode([Int].self, forKey: .from), to: try c.decode([Int].self, forKey: .to), button: button)
            case "scroll":
                self = .scroll(x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y),
                               dx: try c.decodeIfPresent(Int.self, forKey: .dx) ?? 0, dy: try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0)
            case "key": self = .key(try c.decode(String.self, forKey: .keys))
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "未知输入事件 \(type)")
            }
        }
    }

    /// `ui-snapshot` 的正文。`nodes` 按先序排列，父子关系由 `depth` 表达。
    public struct UISnapshot: Codable, Sendable, Equatable {
        public let screen: UIScreen
        public let apps: [UIApp]
        public let app: UIApp?
        public let nodes: [UINode]
        /// 达到深度或节点数上限，树不完整。
        public let truncated: Bool

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            screen = try c.decode(UIScreen.self, forKey: .screen)
            apps = try c.decode([UIApp].self, forKey: .apps)
            app = try c.decodeIfPresent(UIApp.self, forKey: .app)
            nodes = try c.decode([UINode].self, forKey: .nodes)
            truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    /// 主屏：`width`、`height` 是截图像素，`scale` 是每个客户机坐标单位对应的像素数。
    public struct UIScreen: Codable, Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let scale: Double
    }

    public struct UIApp: Codable, Sendable, Equatable {
        public let pid: Int
        public let name: String
        public let bundle: String?
        public let frontmost: Bool

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = try c.decode(Int.self, forKey: .pid)
            name = try c.decode(String.self, forKey: .name)
            bundle = try c.decodeIfPresent(String.self, forKey: .bundle)
            frontmost = try c.decodeIfPresent(Bool.self, forKey: .frontmost) ?? false
        }
    }

    /// 一个元素。`id` 不透明，在下一次快照之前有效；`role` 是客户机系统的原名；`bounds` 是 [x, y, 宽, 高]。
    /// `states`、`actions` 按字符串保留，新代理加的取值不影响解码。
    public struct UINode: Codable, Sendable, Equatable {
        public let id: String
        public let depth: Int
        public let role: String
        public let subrole: String?
        public let name: String?
        public let value: String?
        public let description: String?
        public let bounds: [Int]?
        public let states: [String]
        public let actions: [String]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            depth = try c.decode(Int.self, forKey: .depth)
            role = try c.decode(String.self, forKey: .role)
            subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            bounds = try c.decodeIfPresent([Int].self, forKey: .bounds)
            states = try c.decodeIfPresent([String].self, forKey: .states) ?? []
            actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        }
    }
}
