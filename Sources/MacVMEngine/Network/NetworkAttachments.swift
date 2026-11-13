import Foundation
import MacVMModel
import SystemConfiguration
@preconcurrency import Virtualization

public enum NetworkAttachments {
    static func make(for net: NetworkConfig) throws -> VZNetworkDeviceAttachment {
        switch net.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .bridged:
            guard let interface = net.interface else {
                throw MacVMError.invalidConfig(String(l10n: "Bridged networking needs a host network interface"))
            }
            return try bridged(to: interface)
        case .vmnetShared, .vmnetHost:
            throw MacVMError.unsupported(String(l10n: "vmnet networking isn't implemented yet"))
        }
    }

    /// 签名里没有 `Entitlements.vmNetworking` 的进程报 `MacVMError.entitlementMissing`。
    private static func bridged(to name: String) throws -> VZNetworkDeviceAttachment {
        guard canBridge else {
            throw MacVMError.entitlementMissing(String(l10n: "Bridged networking needs the \(Entitlements.vmNetworking) entitlement, which only the MacVM app signed for it has"))
        }
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        guard let interface = interfaces.first(where: { $0.identifier == name }) else {
            let available = interfaces.map(\.identifier).joinedAsList()
            throw MacVMError.invalidConfig(String(l10n: "No bridgeable network interface named \(name) (available: \(available))"))
        }
        return VZBridgedNetworkDeviceAttachment(interface: interface)
    }

    /// 本进程能否组装桥接网卡。
    public static var canBridge: Bool { Entitlements.has(Entitlements.vmNetworking) }

    public struct BridgeInterface: Sendable, Hashable, Identifiable {
        /// BSD 名，如 `en0`。
        public let identifier: String
        /// 系统设置里显示的名称，如 Wi-Fi。
        public let name: String
        public let isWiFi: Bool

        public var id: String { identifier }
    }

    /// 宿主上可桥接的网卡。
    public static var bridgeInterfaces: [BridgeInterface] {
        let wiFi = wiFiInterfaceNames
        return VZBridgedNetworkInterface.networkInterfaces.map {
            BridgeInterface(identifier: $0.identifier, name: $0.localizedDisplayName ?? $0.identifier, isWiFi: wiFi.contains($0.identifier))
        }
    }

    /// 宿主上 Wi-Fi 网卡的 BSD 名。
    private static var wiFiInterfaceNames: Set<String> {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return Set(all.compactMap { interface in
            guard SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211 else { return nil }
            return SCNetworkInterfaceGetBSDName(interface) as String?
        })
    }

    public static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}
