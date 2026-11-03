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
    public let bridgedNetworking: Bool
    public let bridgeInterfaces: [String]
    public let saveRestore: Bool
    public let libraryPath: String

    public static func current() -> HostCapabilities {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let bridges = NetworkAttachments.bridgeableInterfaces.map(\.identifier)
        var saveRestore = false
        if #available(macOS 14, *) { saveRestore = true }
        return HostCapabilities(
            hostOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            performanceCores: HostInfo.performanceCoreCount,
            physicalMemory: HostInfo.physicalMemory,
            virtualization: VZVirtualMachine.isSupported,
            windows: WindowsSupport.isAvailable,
            qemu: QEMUInstallation.locate()?.binary.path,
            rosetta: VZLinuxRosettaDirectoryShare.availability == .installed,
            bridgedNetworking: Entitlements.has(Entitlements.bridgedNetworking) && !bridges.isEmpty,
            bridgeInterfaces: bridges,
            saveRestore: saveRestore,
            libraryPath: VMLibrary.default.root.path
        )
    }
}
