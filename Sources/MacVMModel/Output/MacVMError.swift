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
    /// 客户机系统没给代理所需的权限（如 macOS 的辅助功能、屏幕录制），要在客户机里授权。
    case permissionDenied(String)

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
        case .permissionDenied: "permission_denied"
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
        case .permissionDenied: 22
        }
    }

    public var message: String {
        switch self {
        case .vmNotFound(let name): String(l10n: "Virtual machine not found: \(name)")
        case .alreadyExists(let name): String(l10n: "Already exists: \(name)")
        case .alreadyRunning(let name): String(l10n: "Virtual machine is already running: \(name)")
        case .notRunning(let name): String(l10n: "Virtual machine isn't running: \(name)")
        case .snapshotNotFound(let what): String(l10n: "Snapshot not found: \(what)")
        case .templateNotFound(let name): String(l10n: "Template not found: \(name)")
        case .invalidConfig(let m), .unsupported(let m), .entitlementMissing(let m),
             .timeout(let m), .io(let m), .engine(let m), .permissionDenied(let m): m
        }
    }
}

extension MacVMError {
    /// 每种错误各一个样例，用于生成帮助与文档里的退出码表。
    public static let catalog: [MacVMError] = [
        .vmNotFound(""), .alreadyExists(""), .alreadyRunning(""), .notRunning(""), .invalidConfig(""),
        .unsupported(""), .entitlementMissing(""), .timeout(""), .io(""), .engine(""), .snapshotNotFound(""),
        .templateNotFound(""), .permissionDenied(""),
    ]

    public var summary: String {
        switch self {
        case .vmNotFound: String(l10n: "VM not found")
        case .alreadyExists: String(l10n: "A VM or template with this name already exists")
        case .alreadyRunning: String(l10n: "VM is already running")
        case .notRunning: String(l10n: "VM is not running")
        case .invalidConfig: String(l10n: "Invalid configuration or argument")
        case .unsupported: String(l10n: "Not supported on this Mac or VM")
        case .entitlementMissing: String(l10n: "Code signature lacks a required entitlement")
        case .timeout: String(l10n: "Timed out")
        case .io: String(l10n: "File or socket I/O error")
        case .engine: String(l10n: "Virtualization.framework error")
        case .snapshotNotFound: String(l10n: "Snapshot not found")
        case .templateNotFound: String(l10n: "Template not found")
        case .permissionDenied: String(l10n: "The guest hasn't granted the agent a required permission")
        }
    }
}

extension MacVMError {
    /// 系统调用失败：`<what>: <strerror(code)>`。`what` 是一整句失败说明（如 "Couldn't read X"），或系统调用名、路径。
    public static func posix(_ what: String, code: Int32 = errno) -> MacVMError {
        .io(String(l10n: "\(what): \(String(cString: strerror(code)))"))
    }
}

extension MacVMError: LocalizedError {
    public var errorDescription: String? { message }
}
