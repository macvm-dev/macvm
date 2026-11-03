import Foundation

/// 与客户机代理通信的消息类型，字段与编码由协议文档 agent.md 定义。
public enum AgentProtocol {
    public static let port: UInt32 = 6100
    static let maxFrame = 1 << 20

    public struct ExecRequest: Codable, Sendable, Equatable {
        public var argv: [String]
        public var user: String?
        public var cwd: String?
        public var env: [String: String]?
        public var tty: Bool?
        public var cols: Int?
        public var rows: Int?

        public init(argv: [String], user: String? = nil, cwd: String? = nil, env: [String: String]? = nil, tty: Bool = false, cols: Int? = nil, rows: Int? = nil) {
            self.argv = argv
            self.user = user
            self.cwd = cwd
            self.env = env
            self.tty = tty ? true : nil
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Request: Codable, Sendable, Equatable {
        case info
        case exec(ExecRequest)
        case forward(port: UInt16)
        case shutdown(reboot: Bool)
        case setTime(unixMs: Int64)
        case clipboardGet
        case clipboardSet(text: String)
        case mount(tag: String, path: String, readOnly: Bool)
        case display(width: Int, height: Int)
        case cursorWatch
        case displayScale(percent: Int)
        /// 随后发送 `size` 字节的驱动包，见 `WindowsGPUDriver.push`。
        case gpuDriver(sha256: String, size: Int)

        private enum Keys: String, CodingKey { case op, port, reboot, text, tag, path, unix_ms, read_only, width, height, percent, sha256, size }

        public func encode(to encoder: any Encoder) throws {
            if case .exec(let req) = self {
                try req.encode(to: encoder)
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode("exec", forKey: .op)
                return
            }
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .info: try c.encode("info", forKey: .op)
            case .exec: break
            case .forward(let port): try c.encode("forward", forKey: .op); try c.encode(port, forKey: .port)
            case .shutdown(let reboot): try c.encode("shutdown", forKey: .op); try c.encode(reboot, forKey: .reboot)
            case .setTime(let ms): try c.encode("set-time", forKey: .op); try c.encode(ms, forKey: .unix_ms)
            case .clipboardGet: try c.encode("clipboard-get", forKey: .op)
            case .clipboardSet(let text): try c.encode("clipboard-set", forKey: .op); try c.encode(text, forKey: .text)
            case .mount(let tag, let path, let ro):
                try c.encode("mount", forKey: .op); try c.encode(tag, forKey: .tag); try c.encode(path, forKey: .path); try c.encode(ro, forKey: .read_only)
            case .cursorWatch: try c.encode("cursor-watch", forKey: .op)
            case .displayScale(let percent): try c.encode("display-scale", forKey: .op); try c.encode(percent, forKey: .percent)
            case .gpuDriver(let sha256, let size):
                try c.encode("gpu-driver", forKey: .op); try c.encode(sha256, forKey: .sha256); try c.encode(size, forKey: .size)
            case .display(let width, let height):
                try c.encode("display", forKey: .op); try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
            }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .op) {
            case "info": self = .info
            case "exec": self = .exec(try ExecRequest(from: decoder))
            case "forward": self = .forward(port: try c.decode(UInt16.self, forKey: .port))
            case "shutdown": self = .shutdown(reboot: try c.decodeIfPresent(Bool.self, forKey: .reboot) ?? false)
            case "set-time": self = .setTime(unixMs: try c.decode(Int64.self, forKey: .unix_ms))
            case "clipboard-get": self = .clipboardGet
            case "clipboard-set": self = .clipboardSet(text: try c.decode(String.self, forKey: .text))
            case "mount":
                self = .mount(tag: try c.decode(String.self, forKey: .tag), path: try c.decode(String.self, forKey: .path),
                              readOnly: try c.decodeIfPresent(Bool.self, forKey: .read_only) ?? false)
            case "display": self = .display(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height))
            case "cursor-watch": self = .cursorWatch
            case "display-scale": self = .displayScale(percent: try c.decode(Int.self, forKey: .percent))
            case "gpu-driver": self = .gpuDriver(sha256: try c.decode(String.self, forKey: .sha256), size: try c.decode(Int.self, forKey: .size))
            case let op: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "未知操作 \(op)")
            }
        }
    }

    public struct Info: Codable, Sendable, Equatable {
        public let version: String
        public let os: String
        public let hostname: String
        public let ipv4: [String]
        public let memTotal: UInt64
        public let memAvailable: UInt64
        public let uptimeMs: UInt64

        enum CodingKeys: String, CodingKey {
            case version, os, hostname, ipv4
            case memTotal = "mem_total", memAvailable = "mem_available", uptimeMs = "uptime_ms"
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        public let ok: Bool
        public let error: String?
        public let info: Info?
        public let text: String?
    }

    /// `cursor-watch` 之后逐行推送的客户机光标；`bgra` 为 Base64 的逐像素 B G R A（非预乘），自上而下。
    struct CursorShape: Decodable {
        var hidden = false
        var width = 0
        var height = 0
        var hot_x = 0
        var hot_y = 0
        var bgra = ""
        var system: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
            hot_x = try c.decodeIfPresent(Int.self, forKey: .hot_x) ?? 0
            hot_y = try c.decodeIfPresent(Int.self, forKey: .hot_y) ?? 0
            bgra = try c.decodeIfPresent(String.self, forKey: .bgra) ?? ""
            system = try c.decodeIfPresent(String.self, forKey: .system)
        }

        private enum CodingKeys: String, CodingKey { case hidden, width, height, hot_x, hot_y, bgra, system }
    }

    enum FrameKind: UInt8 {
        case stdin = 0, stdout, stderr, resize, exit, stdinEOF
    }

    struct ExitStatus: Codable {
        let code: Int32
        let signal: Int32?
    }
}
