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
        /// `stop` 超时时客户机里还没退出、可能挡住关机的 App；没有时不输出。
        public let blockingApps: [GuestApp]?
    }

    public static func success(_ result: Result) -> Self {
        .init(schemaVersion: schemaVersion, result: result, error: nil)
    }

    public static func failure(_ error: MacVMError, blockingApps: [GuestApp]? = nil) -> JSONEnvelope<Result> {
        .init(schemaVersion: schemaVersion, result: nil, error: .init(code: error.code, message: error.message, blockingApps: blockingApps))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// 带附加字段的错误：`code` 与退出码取自 `error`，附加字段只出现在 `--json` 的 `error` 里，人读输出只有消息。
public struct DetailedError: Error, Sendable {
    public let error: MacVMError
    public let blockingApps: [GuestApp]?

    public init(error: MacVMError, blockingApps: [GuestApp]? = nil) {
        self.error = error
        self.blockingApps = blockingApps
    }
}

/// 客户机里运行着的一个 App。
public struct GuestApp: Codable, Sendable, Equatable {
    public let name: String
    public let bundleId: String?
    public let pid: Int

    public init(name: String, bundleId: String?, pid: Int) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
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
