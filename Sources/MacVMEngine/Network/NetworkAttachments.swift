import Foundation
import MacVMModel
@preconcurrency import Virtualization

public enum NetworkAttachments {
    /// `bridge` 是 `BridgeSession` 交来的 socket；为 nil 时（只组装配置、不开机）接一对临时 socket，配置照样能校验。
    static func make(for net: NetworkConfig, bridge: FileHandle?) throws -> VZNetworkDeviceAttachment {
        switch net.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .bridged:
            return VZFileHandleNetworkDeviceAttachment(fileHandle: try bridge ?? placeholderSocket())
        case .vmnetShared, .vmnetHost:
            throw MacVMError.unsupported(String(l10n: "vmnet networking isn't implemented yet"))
        }
    }

    private static func placeholderSocket() throws -> FileHandle {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { throw MacVMError.posix("socketpair") }
        close(fds[1])
        return FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    }

    public struct BridgeInterface: Sendable, Hashable {
        /// BSD 名，如 en0。
        public let identifier: String
        /// 系统设置里显示的名称，如 Wi-Fi。
        public let name: String
    }

    /// 主机上可桥接的网卡；实际桥接还需要网络辅助程序。
    public static var bridgeInterfaces: [BridgeInterface] {
        VZBridgedNetworkInterface.networkInterfaces.map { BridgeInterface(identifier: $0.identifier, name: $0.localizedDisplayName ?? $0.identifier) }
    }

    public static var bridgeableInterfaces: [String] { bridgeInterfaces.map(\.identifier) }

    /// 要桥接的网卡 BSD 名：`name` 为 nil 时取第一块可桥接的网卡。
    public static func bridgeInterface(named name: String?) throws -> String {
        let available = bridgeableInterfaces
        if let name {
            guard available.contains(name) else {
                throw MacVMError.invalidConfig(String(l10n: "Couldn't find a bridgeable network interface named \(name); available: \(available.joinedAsList())"))
            }
            return name
        }
        guard let first = available.first else { throw MacVMError.unsupported(String(l10n: "This Mac has no bridgeable network interface")) }
        return first
    }

    public static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}
