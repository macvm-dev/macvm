import Foundation

/// 运行中虚拟机的控制 socket 协议：每个连接发一行 JSON 请求，收一行 JSON 响应。
/// `connect` 成功响应之后，该连接变为到客户机 vsock 端口的原始字节管道。
public enum ControlRequest: Codable, Sendable, Equatable {
    case status
    case connect(port: UInt32)
    case stop(force: Bool)
    case suspend
    case pause
    case resume
    /// 把当前画面存成 PNG 到 `path`（宿主路径）。
    case screenshot(path: String)
    /// 把显示输出调整为 `width`×`height` 像素。
    case display(width: Int, height: Int)

    private enum CodingKeys: String, CodingKey { case op, force, port, path, width, height }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "status": self = .status
        case "connect": self = .connect(port: try c.decode(UInt32.self, forKey: .port))
        case "stop": self = .stop(force: try c.decodeIfPresent(Bool.self, forKey: .force) ?? false)
        case "suspend": self = .suspend
        case "pause": self = .pause
        case "resume": self = .resume
        case "screenshot": self = .screenshot(path: try c.decode(String.self, forKey: .path))
        case "display": self = .display(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height))
        case let op: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "未知操作 \(op)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try c.encode("status", forKey: .op)
        case .connect(let port):
            try c.encode("connect", forKey: .op)
            try c.encode(port, forKey: .port)
        case .stop(let force):
            try c.encode("stop", forKey: .op)
            try c.encode(force, forKey: .force)
        case .suspend: try c.encode("suspend", forKey: .op)
        case .pause: try c.encode("pause", forKey: .op)
        case .resume: try c.encode("resume", forKey: .op)
        case .screenshot(let path):
            try c.encode("screenshot", forKey: .op)
            try c.encode(path, forKey: .path)
        case .display(let width, let height):
            try c.encode("display", forKey: .op)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
        }
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var state: String?
    public var pid: Int32?
    public var canSuspend: Bool?
    public var errorCode: String?
    public var message: String?

    public init(ok: Bool, state: String? = nil, pid: Int32? = nil, canSuspend: Bool? = nil, errorCode: String? = nil, message: String? = nil) {
        self.ok = ok
        self.state = state
        self.pid = pid
        self.canSuspend = canSuspend
        self.errorCode = errorCode
        self.message = message
    }
}
