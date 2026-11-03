import Foundation
import MacVMModel
@preconcurrency import Virtualization

public enum NetworkAttachments {
    static func make(for net: NetworkConfig) throws -> VZNetworkDeviceAttachment {
        switch net.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .bridged:
            guard Entitlements.has(Entitlements.bridgedNetworking) else {
                throw MacVMError.entitlementMissing("桥接网络需要 \(Entitlements.bridgedNetworking) entitlement，当前签名未包含")
            }
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            let wanted = net.interface
            guard let interface = interfaces.first(where: { wanted == nil || $0.identifier == wanted }) else {
                let names = interfaces.map(\.identifier).joined(separator: ", ")
                throw MacVMError.invalidConfig("找不到可桥接的网卡 \(wanted ?? "")，可用：\(names)")
            }
            return VZBridgedNetworkDeviceAttachment(interface: interface)
        case .vmnetShared, .vmnetHost:
            throw MacVMError.unsupported("vmnet 网络尚未实现")
        }
    }

    /// 主机上可桥接的网卡；实际桥接还需要 entitlement。
    public static var bridgeableInterfaces: [(identifier: String, name: String)] {
        VZBridgedNetworkInterface.networkInterfaces.map { ($0.identifier, $0.localizedDisplayName ?? $0.identifier) }
    }

    public static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}
