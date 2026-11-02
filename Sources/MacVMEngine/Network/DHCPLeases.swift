public import Foundation

/// 读取 macOS 内置 DHCP 服务（NAT 与 vmnet shared 模式）的租约表，按 MAC 查 IP。
public enum DHCPLeases {
    public static let defaultPath = "/var/db/dhcpd_leases"

    public static func ipAddress(forMAC mac: String, hostname: String? = nil, leasesPath: String = defaultPath) -> String? {
        guard let text = try? String(contentsOfFile: leasesPath, encoding: .utf8) else { return nil }
        return ipAddress(forMAC: mac, hostname: hostname, in: text)
    }

    /// 优先按 MAC 匹配。客户机若用 DUID 作客户端标识，租约里没有 MAC，再按 `hostname` 匹配；
    /// 主机名可能被已删除的同名虚拟机用过，所以这一步只认 `now` 时仍未过期的租约。
    /// 同一键有多条租约时取 lease 字段（到期时间）最大的那条。
    public static func ipAddress(forMAC mac: String, hostname: String? = nil, in text: String, now: Date = Date()) -> String? {
        let leases = parse(text)
        let wanted = normalize(mac)
        if let hit = newest(leases.filter { $0.hardware.map(normalize) == wanted }) { return hit }
        guard let hostname else { return nil }
        let current = UInt64(now.timeIntervalSince1970)
        return newest(leases.filter { $0.name == hostname && $0.lease > current })
    }

    private struct Lease {
        var name: String?
        var ip: String?
        /// 仅当类型为 1（以太网）时有值。
        var hardware: String?
        var lease: UInt64 = 0
    }

    private static func parse(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var current = Lease()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                current = Lease()
            } else if line == "}" {
                leases.append(current)
            } else if let v = line.value(of: "name") {
                current.name = v
            } else if let v = line.value(of: "ip_address") {
                current.ip = v
            } else if let v = line.value(of: "hw_address") {
                let parts = v.split(separator: ",", maxSplits: 1)
                if parts.count == 2, parts[0] == "1" { current.hardware = String(parts[1]) }
            } else if let v = line.value(of: "lease") {
                current.lease = UInt64(v.dropFirst(2), radix: 16) ?? 0
            }
        }
        return leases
    }

    private static func newest(_ leases: [Lease]) -> String? {
        leases.filter { $0.ip != nil }.max { $0.lease < $1.lease }?.ip
    }

    static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { part in
            let trimmed = part.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }
}

private extension String {
    func value(of key: String) -> String? {
        hasPrefix(key + "=") ? String(dropFirst(key.count + 1)) : nil
    }
}
