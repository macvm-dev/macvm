import Foundation

/// IPv4 地址与主机字节序 `UInt32` 之间的转换。
public enum IPv4 {
    /// 只认点分十进制，不允许前后空白；各段的前导零按十进制读。不合法时返回 nil。
    public static func parse(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    public static func format(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// 前 `prefix` 位为 1 的掩码；`prefix` 超出 0…32 时按边界算。
    public static func mask(prefix: Int) -> UInt32 {
        let bits = min(max(prefix, 0), 32)
        return bits == 0 ? 0 : UInt32.max << (32 - bits)
    }
}

/// 桥接网卡在客户机里的静态 IPv4 配置。这些值会拼进客户机里的命令，下发前必须过 `validate()`。
public struct StaticIPv4: Codable, Sendable, Equatable {
    public static let prefixLengths = 8...30
    /// 客户端能填的 DNS 服务器个数上限。
    public static let maxDNSServers = 3

    public var address: String
    public var prefixLength: Int
    public var gateway: String
    /// 为空时用 `gateway`。
    public var dns: [String]

    /// 解析 `a.b.c.d/前缀长度` 形式的地址，各项去掉前后空白后校验，不合法时抛 `MacVMError.invalidConfig`；存规范化后的点分串。
    public init(cidr: String, gateway: String, dns: [String] = []) throws {
        let text = cidr.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPv4.parse(String(parts[0])), let prefixLength = Int(parts[1]) else {
            throw MacVMError.invalidConfig(String(l10n: "Not an IPv4 address with a prefix length, such as 192.168.1.10/24: \(cidr)"))
        }
        let gatewayValue = try Self.parse(gateway.trimmingCharacters(in: .whitespaces))
        let dnsValues = try dns.map { try Self.parse($0.trimmingCharacters(in: .whitespaces)) }
        try Self.check(address: address, prefixLength: prefixLength, gateway: gatewayValue, dns: dnsValues)
        self.address = IPv4.format(address)
        self.prefixLength = prefixLength
        self.gateway = IPv4.format(gatewayValue)
        self.dns = dnsValues.map(IPv4.format)
    }

    /// 不校验，下发前另行 `validate()`；没有 `dns` 时按空读。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        prefixLength = try c.decode(Int.self, forKey: .prefixLength)
        gateway = try c.decode(String.self, forKey: .gateway)
        dns = try c.decodeIfPresent([String].self, forKey: .dns) ?? []
    }

    /// 地址、网关与 DNS 都得是规范的 IPv4 点分串，前缀长度在 `prefixLengths` 内，DNS 不超过 `maxDNSServers` 个；
    /// 地址不能是网段号、广播地址，也不能落在 0/8、127/8、169.254/16、224/4 及以上；网关与地址同网段、不等于地址，
    /// 也不能是网段号或广播地址。
    public func validate() throws {
        try Self.check(address: Self.parse(address, canonical: true), prefixLength: prefixLength,
                       gateway: Self.parse(gateway, canonical: true), dns: dns.map { try Self.parse($0, canonical: true) })
    }

    public var dnsServers: [String] { dns.isEmpty ? [gateway] : dns }

    /// 点分形式的子网掩码。
    public var subnetMask: String { IPv4.format(IPv4.mask(prefix: prefixLength)) }

    public var cidr: String { "\(address)/\(prefixLength)" }

    /// `canonical` 时只认规范的点分串：存下的值原样进客户机命令并按字面比对，`inet_pton` 放行的前导零在客户机里读法不一。
    private static func parse(_ text: String, canonical: Bool = false) throws -> UInt32 {
        guard let value = IPv4.parse(text), !canonical || IPv4.format(value) == text else {
            throw MacVMError.invalidConfig(String(l10n: "Not an IPv4 address: \(text)"))
        }
        return value
    }

    private static func check(address: UInt32, prefixLength: Int, gateway: UInt32, dns: [UInt32]) throws {
        guard prefixLengths.contains(prefixLength) else {
            throw MacVMError.invalidConfig(String(l10n: "Prefix length must be \(prefixLengths.lowerBound) to \(prefixLengths.upperBound): \(prefixLength)"))
        }
        guard dns.count <= maxDNSServers else {
            throw MacVMError.invalidConfig(String(l10n: "At most \(maxDNSServers) DNS servers are allowed"))
        }
        let first = address >> 24
        guard first != 0, first != 127, first < 224, address & 0xFFFF_0000 != 0xA9FE_0000 else {
            throw MacVMError.invalidConfig(String(l10n: "\(IPv4.format(address)) can't be used as a guest address"))
        }
        let mask = IPv4.mask(prefix: prefixLength)
        let host = address & ~mask
        guard host != 0, host != ~mask else {
            throw MacVMError.invalidConfig(String(l10n: "\(IPv4.format(address)) is the network or broadcast address of its subnet"))
        }
        guard gateway & mask == address & mask else {
            throw MacVMError.invalidConfig(String(l10n: "Gateway \(IPv4.format(gateway)) isn't in the subnet \(IPv4.format(address & mask))/\(prefixLength)"))
        }
        guard gateway != address else {
            throw MacVMError.invalidConfig(String(l10n: "The gateway can't be the same as the address"))
        }
        let gatewayHost = gateway & ~mask
        guard gatewayHost != 0, gatewayHost != ~mask else {
            throw MacVMError.invalidConfig(String(l10n: "Gateway \(IPv4.format(gateway)) is the network or broadcast address of its subnet"))
        }
    }
}
