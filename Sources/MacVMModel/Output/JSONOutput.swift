public import Foundation

/// `--json` 输出的外层信封：成功时 `result` 有值，失败时 `error` 有值。
/// 结构变化不兼容时提升 `schemaVersion`。
public struct JSONEnvelope<Result: Encodable & Sendable>: Encodable, Sendable {
    public static var schemaVersion: Int { 1 }

    public let schemaVersion: Int
    public let result: Result?
    public let error: ErrorBody?

    public struct ErrorBody: Encodable, Sendable {
        public let code: String
        public let message: String
    }

    public static func success(_ result: Result) -> Self {
        .init(schemaVersion: schemaVersion, result: result, error: nil)
    }

    public static func failure(_ error: MacVMError) -> JSONEnvelope<Result> {
        .init(schemaVersion: schemaVersion, result: nil, error: .init(code: error.code, message: error.message))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// `macvm ls` / `macvm status` 中单台虚拟机的视图。
public struct VMSummary: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case stopped, running, suspended }

    public let name: String
    public let os: GuestOS
    public let state: State
    public let cpuCount: Int
    public let memorySize: UInt64
    public let path: String
    public let pid: Int32?
    public let ipAddress: String?

    public init(name: String, os: GuestOS, state: State, cpuCount: Int, memorySize: UInt64, path: String, pid: Int32?, ipAddress: String?) {
        self.name = name
        self.os = os
        self.state = state
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.path = path
        self.pid = pid
        self.ipAddress = ipAddress
    }
}

/// `macvm template ls` 中单个模板的视图。
public struct TemplateSummary: Codable, Sendable, Equatable {
    public let name: String
    public let os: GuestOS
    public let engine: Engine
    public let cpuCount: Int
    public let memorySize: UInt64
    /// 系统盘容量；读不到时为 nil。
    public let diskSize: UInt64?
    public let path: String

    public init(name: String, os: GuestOS, engine: Engine, cpuCount: Int, memorySize: UInt64, diskSize: UInt64?, path: String) {
        self.name = name
        self.os = os
        self.engine = engine
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.path = path
    }
}
