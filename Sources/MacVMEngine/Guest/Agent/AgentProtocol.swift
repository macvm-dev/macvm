import Foundation
import MacVMModel

/// 与客户机代理通信的消息类型，字段与编码由宿主与代理之间的协议文档定义。
public enum AgentProtocol {
    public static let port: UInt32 = 6100
    static let maxFrame = 1 << 20
    /// 响应行之后正文（`Response.size`）的字节数上限。
    static let maxBody = 64 << 20
    /// `Info.features` 里表示支持 `ui-*` 请求的项。
    static let featureUI = "ui"
    /// `Info.features` 里表示支持 `files-put`、`files-get` 与剪贴板里的文件的项。
    static let featureFiles = "files"
    /// `Info.features` 里表示支持 `drag-files` 的项。
    static let featureDrag = "drag"

    /// `files-put` 把文件放到哪里。
    public enum PutTarget: Sendable, Equatable {
        /// 客户机上已有的目录。
        case dir(String)
        /// 投放点下的文件夹窗口或桌面；点是主屏宽、高的比例（0–1）。
        case drop(x: Double, y: Double)
        /// 客户机的桌面。
        case desktop
        /// 新的暂存目录，收完后客户机剪贴板换成这些文件。
        case clipboard
    }

    /// 客户机上的一个文件或目录。
    public struct GuestFile: Codable, Sendable, Equatable, Hashable {
        /// 客户机上的绝对路径。
        public let path: String
        public let dir: Bool

        public init(path: String, dir: Bool) {
            self.path = path
            self.dir = dir
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            dir = try c.decodeIfPresent(Bool.self, forKey: .dir) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            if dir { try c.encode(dir, forKey: .dir) }
        }

        private enum CodingKeys: String, CodingKey { case path, dir }
    }

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
        /// 请求之后紧跟 `size` 字节的驱动包，`sha256` 是它的 SHA-256（十六进制）。
        case gpuDriver(sha256: String, size: Int)
        /// 把 Linux 客户机的文件页缓存回收到约 `keep` 字节。
        case trimCache(keep: UInt64)
        /// 应用的无障碍树；成功响应带 `size`，正文是 `UISnapshot`。
        case uiSnapshot(app: String?, maxDepth: Int?, maxNodes: Int?)
        case uiAction(element: String, action: ElementAction, value: String?)
        case uiInput([InputEvent])
        /// 成功响应带 `size`，正文是主屏 PNG。
        case uiScreenshot
        /// 成功响应后宿主发文件流，代理收完再回一行，`files` 是各顶层项的存放路径。
        case filesPut(PutTarget)
        /// 成功响应带 `total`，随后代理发这些路径的文件流。
        case filesGet(paths: [String])
        case dragFiles

        private enum Keys: String, CodingKey {
            case op, port, reboot, text, tag, path, unix_ms, read_only, width, height, percent, sha256, size, keep
            case app, max_depth, max_nodes, element, action, value, events, to, x, y, paths
        }

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
            case .trimCache(let keep): try c.encode("trim-cache", forKey: .op); try c.encode(keep, forKey: .keep)
            case .display(let width, let height):
                try c.encode("display", forKey: .op); try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
            case .uiSnapshot(let app, let maxDepth, let maxNodes):
                try c.encode("ui-snapshot", forKey: .op)
                try c.encodeIfPresent(app, forKey: .app)
                try c.encodeIfPresent(maxDepth, forKey: .max_depth)
                try c.encodeIfPresent(maxNodes, forKey: .max_nodes)
            case .uiAction(let element, let action, let value):
                try c.encode("ui-action", forKey: .op); try c.encode(element, forKey: .element); try c.encode(action, forKey: .action)
                try c.encodeIfPresent(value, forKey: .value)
            case .uiInput(let events): try c.encode("ui-input", forKey: .op); try c.encode(events, forKey: .events)
            case .uiScreenshot: try c.encode("ui-screenshot", forKey: .op)
            case .filesPut(let target):
                try c.encode("files-put", forKey: .op)
                switch target {
                case .dir(let path): try c.encode("dir", forKey: .to); try c.encode(path, forKey: .path)
                case .drop(let x, let y): try c.encode("drop", forKey: .to); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
                case .desktop: try c.encode("drop", forKey: .to)
                case .clipboard: try c.encode("clipboard", forKey: .to)
                }
            case .filesGet(let paths): try c.encode("files-get", forKey: .op); try c.encode(paths, forKey: .paths)
            case .dragFiles: try c.encode("drag-files", forKey: .op)
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
            case "trim-cache": self = .trimCache(keep: try c.decode(UInt64.self, forKey: .keep))
            case "ui-snapshot":
                self = .uiSnapshot(app: try c.decodeIfPresent(String.self, forKey: .app), maxDepth: try c.decodeIfPresent(Int.self, forKey: .max_depth),
                                   maxNodes: try c.decodeIfPresent(Int.self, forKey: .max_nodes))
            case "ui-action":
                self = .uiAction(element: try c.decode(String.self, forKey: .element), action: try c.decode(ElementAction.self, forKey: .action),
                                 value: try c.decodeIfPresent(String.self, forKey: .value))
            case "ui-input": self = .uiInput(try c.decode([InputEvent].self, forKey: .events))
            case "ui-screenshot": self = .uiScreenshot
            case "files-put":
                switch try c.decode(String.self, forKey: .to) {
                case "dir": self = .filesPut(.dir(try c.decode(String.self, forKey: .path)))
                case "drop":
                    if let x = try c.decodeIfPresent(Double.self, forKey: .x), let y = try c.decodeIfPresent(Double.self, forKey: .y) {
                        self = .filesPut(.drop(x: x, y: y))
                    } else {
                        self = .filesPut(.desktop)
                    }
                case "clipboard": self = .filesPut(.clipboard)
                case let to: throw DecodingError.dataCorruptedError(forKey: .to, in: c, debugDescription: "未知目标 \(to)")
                }
            case "files-get": self = .filesGet(paths: try c.decode([String].self, forKey: .paths))
            case "drag-files": self = .dragFiles
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
        /// 代理在这个客户机上支持的可选能力，如 `featureUI`；缺省时没有任何可选能力。
        public let features: [String]?
        /// 客户机里代理可执行文件的 SHA-256（小写十六进制）；缺省时无从比对，按与随程序分发的不同处理。
        public let exeSHA256: String?

        enum CodingKeys: String, CodingKey {
            case version, os, hostname, ipv4, features
            case memTotal = "mem_total", memAvailable = "mem_available", uptimeMs = "uptime_ms", exeSHA256 = "exe_sha256"
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        public let ok: Bool
        public let error: String?
        public let info: Info?
        public let text: String?
        /// 失败时机器可读的原因：`permission` 表示客户机没给代理所需的权限，`restarting` 表示代理随即重启、稍后重试即可。
        public let code: String?
        /// 响应行之后紧跟的正文字节数。
        public let size: Int?
        /// `clipboard-get`、`drag-files` 里的文件，`files-put` 收完后各顶层项的存放路径。
        public let files: [GuestFile]?
        /// `files-get` 随后文件流里普通文件的总字节数。
        public let total: Int64?
        /// `drag-files`：拖放剪贴板的变更计数，按下鼠标时与拖出窗口时不同才说明这次按下开始了拖动；没有时代理只在拖动进行中返回文件。
        public let serial: Int64?

        /// 失败的响应转成错误：缺权限时为 `permissionDenied`，代理随即重启时为 `Restarting`，其余为 `engine`；代理没给原因时用 `fallback`。
        func checked(_ fallback: String = "未知错误") throws -> Response {
            guard ok else {
                let message = error ?? fallback
                switch code {
                case "permission": throw MacVMError.permissionDenied(message)
                case "restarting": throw Restarting(message: message)
                default: throw MacVMError.engine("客户机代理：\(message)")
                }
            }
            return self
        }
    }

    /// 代理回完响应就退出、由客户机的服务管理器重新拉起；等新代理上线后重试同一请求。
    struct Restarting: Error {
        let message: String

        var engineError: MacVMError { .engine("客户机代理：\(message)") }
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

    /// `files-put`、`files-get` 之后文件流的帧类型；帧格式与 exec 帧相同。
    enum FileFrame: UInt8 {
        /// 载荷是 `FileEntry` 的 JSON。
        case entry = 0
        /// 上一个 `file` 条目的内容，合计正好 `size` 字节。
        case data
        case end
        /// 发送方中止，载荷是 UTF-8 的原因。
        case error
    }

    /// 文件流里的一项，先序排列。`path` 以 `/` 分隔，第一段是顶层项的名字。
    struct FileEntry: Codable, Equatable {
        enum Kind: String, Codable { case dir, file, link }

        var path: String
        var kind: Kind
        var size: Int64 = 0
        /// Unix 权限位。
        var mode: UInt16?
        var mtime_ms: Int64?
        var target: String?

        init(path: String, kind: Kind, size: Int64 = 0, mode: UInt16? = nil, mtime_ms: Int64? = nil, target: String? = nil) {
            self.path = path
            self.kind = kind
            self.size = size
            self.mode = mode
            self.mtime_ms = mtime_ms
            self.target = target
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            kind = try c.decode(Kind.self, forKey: .kind)
            size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            mode = try c.decodeIfPresent(UInt16.self, forKey: .mode)
            mtime_ms = try c.decodeIfPresent(Int64.self, forKey: .mtime_ms)
            target = try c.decodeIfPresent(String.self, forKey: .target)
        }

        /// 拆开路径；空段、`.`、`..`、含 `\` 或 NUL 的段都不合法，返回 nil。
        static func split(_ path: String) -> [String]? {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let valid = parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }
            return valid ? parts : nil
        }
    }

    struct ExitStatus: Codable {
        let code: Int32
        let signal: Int32?
    }
}
