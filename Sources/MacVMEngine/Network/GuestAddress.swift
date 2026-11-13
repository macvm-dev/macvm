import Foundation
import MacVMModel

/// 客户机当前的 IPv4 地址：桥接下读 `VMBundle.bridgedAddressURL`，其他模式查主机 DHCP 服务的租约。
enum GuestAddress {
    /// `leases` 返回租约表全文，桥接时不调用。读文件，不要在主线程反复调用。
    static func current(_ bundle: VMBundle, _ config: VMConfig, hostname: String? = nil,
                        leases: () -> String? = DHCPLeases.read) -> String? {
        guard let net = config.networks.first else { return nil }
        if net.mode == .bridged { return BridgedAddress.stored(for: bundle) }
        guard let mac = net.macAddress else { return nil }
        return leases().flatMap { DHCPLeases.ipAddress(forMAC: mac, hostname: hostname, in: $0) }
    }
}
