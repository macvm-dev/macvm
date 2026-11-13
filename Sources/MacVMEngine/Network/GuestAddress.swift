import Foundation
import MacVMModel

/// 客户机当前的 IPv4 地址：桥接下读 `VMBundle.bridgedAddressURL`，其他模式查主机 DHCP 服务的租约。
enum GuestAddress {
    /// `leases` 返回租约表全文，桥接时不调用。读文件，不要在主线程反复调用。
    static func current(_ bundle: VMBundle, _ config: VMConfig, hostname: String? = nil,
                        leases: () -> String? = DHCPLeases.read) -> String? {
        guard let net = config.networks.first else { return nil }
        if net.mode == .bridged {
            let text = (try? String(contentsOf: bundle.bridgedAddressURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 地址会拼进 ssh 的命令行，文件里不是 IPv4 的内容一律不认。
            return text.flatMap { BridgedAddress.ipv4($0) == nil ? nil : $0 }
        }
        guard let mac = net.macAddress else { return nil }
        return leases().flatMap { DHCPLeases.ipAddress(forMAC: mac, hostname: hostname, in: $0) }
    }
}
