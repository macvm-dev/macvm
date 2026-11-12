import Foundation
import MacVMModel
@preconcurrency import Virtualization

public enum NetworkAttachments {
    static func make(for net: NetworkConfig) throws -> VZNetworkDeviceAttachment {
        switch net.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .vmnetShared, .vmnetHost:
            throw MacVMError.unsupported(String(l10n: "vmnet networking isn't implemented yet"))
        }
    }

    public static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}
