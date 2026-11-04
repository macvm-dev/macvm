public import Foundation

/// 对外可见的错误。每个 case 对应固定的 `code`（JSON 输出）与 `exitCode`（进程退出码），
/// 两者都是 CLI 契约，调用方据此分支，已发布的值不能改。
public enum MacVMError: Error, Sendable, Equatable {
    case vmNotFound(String)
    case alreadyExists(String)
    case alreadyRunning(String)
    case notRunning(String)
    case invalidConfig(String)
    case unsupported(String)
    case entitlementMissing(String)
    case timeout(String)
    case io(String)
    case engine(String)
    case snapshotNotFound(String)
    case templateNotFound(String)

    public var code: String {
        switch self {
        case .vmNotFound: "vm_not_found"
        case .alreadyExists: "already_exists"
        case .alreadyRunning: "already_running"
        case .notRunning: "not_running"
        case .invalidConfig: "invalid_config"
        case .unsupported: "unsupported"
        case .entitlementMissing: "entitlement_missing"
        case .timeout: "timeout"
        case .io: "io"
        case .engine: "engine"
        case .snapshotNotFound: "snapshot_not_found"
        case .templateNotFound: "template_not_found"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .vmNotFound: 10
        case .alreadyExists: 11
        case .alreadyRunning: 12
        case .notRunning: 13
        case .invalidConfig: 14
        case .unsupported: 15
        case .entitlementMissing: 16
        case .timeout: 17
        case .io: 18
        case .engine: 19
        case .snapshotNotFound: 20
        case .templateNotFound: 21
        }
    }

    public var message: String {
        switch self {
        case .vmNotFound(let name): "虚拟机不存在：\(name)"
        case .alreadyExists(let name): "已存在：\(name)"
        case .alreadyRunning(let name): "虚拟机已在运行：\(name)"
        case .notRunning(let name): "虚拟机未运行：\(name)"
        case .snapshotNotFound(let what): "快照不存在：\(what)"
        case .templateNotFound(let name): "模板不存在：\(name)"
        case .invalidConfig(let m), .unsupported(let m), .entitlementMissing(let m),
             .timeout(let m), .io(let m), .engine(let m): m
        }
    }
}

extension MacVMError {
    /// 每种错误各一个样例，用于生成帮助与文档里的退出码表。
    public static let catalog: [MacVMError] = [
        .vmNotFound(""), .alreadyExists(""), .alreadyRunning(""), .notRunning(""), .invalidConfig(""),
        .unsupported(""), .entitlementMissing(""), .timeout(""), .io(""), .engine(""), .snapshotNotFound(""),
        .templateNotFound(""),
    ]

    public var summary: String {
        switch self {
        case .vmNotFound: "虚拟机不存在"
        case .alreadyExists: "同名虚拟机或模板已存在"
        case .alreadyRunning: "虚拟机已在运行"
        case .notRunning: "虚拟机未运行"
        case .invalidConfig: "配置或参数无效"
        case .unsupported: "本机或该虚拟机不支持此操作"
        case .entitlementMissing: "签名缺少所需 entitlement"
        case .timeout: "等待超时"
        case .io: "文件或 socket 读写失败"
        case .engine: "Virtualization.framework 报错"
        case .snapshotNotFound: "快照不存在"
        case .templateNotFound: "模板不存在"
        }
    }
}

extension MacVMError {
    /// 系统调用失败：`what 失败：<strerror(code)>`。
    public static func posix(_ what: String, code: Int32 = errno) -> MacVMError {
        .io("\(what) 失败：\(String(cString: strerror(code)))")
    }
}

extension MacVMError: LocalizedError {
    public var errorDescription: String? { message }
}
