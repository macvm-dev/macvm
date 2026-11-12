import Foundation
import MacVMModel

/// 客户机当前的 IPv4 地址，查主机 DHCP 服务的租约。
enum GuestAddress {
    /// `leases` 返回租约表全文。读文件，不要在主线程反复调用。
    static func current(_ config: VMConfig, hostname: String? = nil,
                        leases: () -> String? = DHCPLeases.read) -> String? {
        guard let mac = config.networks.first?.macAddress else { return nil }
        return leases().flatMap { DHCPLeases.ipAddress(forMAC: mac, hostname: hostname, in: $0) }
    }
}
