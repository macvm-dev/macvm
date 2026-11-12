import Foundation
import MacVMModel
@preconcurrency import Virtualization

/// 本机与本进程签名能支持哪些功能。
public struct HostCapabilities: Codable, Sendable {
    public let hostOS: String
    public let performanceCores: Int
    public let physicalMemory: UInt64
    public let virtualization: Bool
    public let windows: Bool
    /// Homebrew 安装的 qemu-system-aarch64 路径；未安装时为 nil。
    public let qemu: String?
    public let rosetta: Bool
    /// 支持的系统版本都有挂起恢复接口，取决于能否虚拟化；具体虚拟机能否挂起看它自己的配置。
    public let saveRestore: Bool
    public let libraryPath: String
    public let downloadPath: String
    public let templatePath: String

    public static func current() -> HostCapabilities {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let virtualization = VZVirtualMachine.isSupported
        return HostCapabilities(
            hostOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            performanceCores: HostInfo.performanceCoreCount,
            physicalMemory: HostInfo.physicalMemory,
            virtualization: virtualization,
            windows: WindowsSupport.isAvailable,
            qemu: QEMUInstallation.locate()?.binary.path,
            rosetta: VZLinuxRosettaDirectoryShare.availability == .installed,
            saveRestore: virtualization,
            libraryPath: VMLibrary.default.root.path,
            downloadPath: DownloadCache.root.path,
            templatePath: TemplateLibrary.default.root.path
        )
    }
}
