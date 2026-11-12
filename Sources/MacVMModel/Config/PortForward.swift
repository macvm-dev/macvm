import Foundation

/// 宿主 TCP 端口到客户机 TCP 端口的转发。宿主监听 `address:hostPort`，每个连进来的连接接到客户机的 `guestPort`。
public struct PortForward: Codable, Sendable, Hashable {
    /// 宿主上监听的 IPv4 地址：`127.0.0.1` 只有本机能连，`0.0.0.0` 局域网里的其他设备也能连。
    public var address: String
    public var hostPort: UInt16
    public var guestPort: UInt16

    public static let defaultAddress = "127.0.0.1"
    public static let anyAddress = "0.0.0.0"

    public init(address: String = PortForward.defaultAddress, hostPort: UInt16, guestPort: UInt16) {
        self.address = address
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    /// 规范写法 `地址:宿主端口:客户机端口`，`parse` 的逆运算。
    public var spec: String { "\(address):\(hostPort):\(guestPort)" }

    /// 解析 `[地址:]宿主端口:客户机端口`；地址只认 IPv4 点分十进制，端口 1–65535。
    public static func parse(_ text: String) throws -> PortForward {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            throw MacVMError.invalidConfig(String(l10n: "Port forward must be [address:]host-port:guest-port, e.g. 8080:80: \(text)"))
        }
        let address = parts.count == 3 ? parts[0] : defaultAddress
        guard isIPv4(address) else { throw MacVMError.invalidConfig(String(l10n: "Not an IPv4 address: \(address)")) }
        return PortForward(address: address, hostPort: try port(parts[parts.count - 2]), guestPort: try port(parts[parts.count - 1]))
    }

    /// 两条转发不能同时监听：宿主端口相同，且地址相同或有一方是 `anyAddress`。
    public func conflicts(with other: PortForward) -> Bool {
        hostPort == other.hostPort && (address == other.address || address == Self.anyAddress || other.address == Self.anyAddress)
    }

    private static func port(_ text: String) throws -> UInt16 {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }), let value = UInt16(text), value > 0 else {
            throw MacVMError.invalidConfig(String(l10n: "Port must be a number from 1 to 65535: \(text)"))
        }
        return value
    }

    public static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1
    }
}

extension PortForward {
    /// 逐条解析并检查彼此冲突。
    public static func parseAll(_ specs: [String]) throws -> [PortForward] {
        var result: [PortForward] = []
        for spec in specs { try add(parse(spec), to: &result) }
        return result
    }

    static func add(_ forward: PortForward, to list: inout [PortForward]) throws {
        if let existing = list.first(where: { $0.conflicts(with: forward) }) {
            throw MacVMError.invalidConfig(String(l10n: "Host port \(String(forward.hostPort)) is already forwarded (\(existing.spec))"))
        }
        list.append(forward)
    }
}

extension VMConfig {
    /// 与已有的转发冲突时报错。
    public mutating func addForward(_ forward: PortForward) throws {
        try PortForward.add(forward, to: &forwards)
    }

    /// 按宿主端口、`地址:宿主端口` 或完整写法移除，没有匹配的时报错。
    public mutating func removeForward(_ text: String) throws {
        let before = forwards.count
        forwards.removeAll { forward in
            text == "\(forward.hostPort)" || text == "\(forward.address):\(forward.hostPort)" || text == forward.spec
                || (try? PortForward.parse(text)) == forward
        }
        guard forwards.count < before else { throw MacVMError.invalidConfig(String(l10n: "No port forward matches \(text)")) }
    }
}
