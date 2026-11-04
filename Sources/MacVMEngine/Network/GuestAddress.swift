import Foundation
import MacVMModel

/// 客户机当前的 IPv4 地址：NAT 下查主机 DHCP 服务的租约，桥接下读 `VMBundle.bridgedAddressURL`。
enum GuestAddress {
    /// `leases` 返回租约表全文，只在 NAT 下调用。读文件，不要在主线程反复调用。
    static func current(_ bundle: VMBundle, _ config: VMConfig, hostname: String? = nil,
                        leases: () -> String? = DHCPLeases.read) -> String? {
        guard let net = config.networks.first, let mac = net.macAddress else { return nil }
        if net.mode == .bridged {
            let text = (try? String(contentsOf: bundle.bridgedAddressURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        return leases().flatMap { DHCPLeases.ipAddress(forMAC: mac, hostname: hostname, in: $0) }
    }
}
