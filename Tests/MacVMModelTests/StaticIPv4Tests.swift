import Foundation
import MacVMModel
import Testing

struct StaticIPv4Tests {
    private func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as MacVMError {
            return error.code
        } catch {
            return "other"
        }
    }

    @Test func normalizesDottedQuads() throws {
        let value = try StaticIPv4(cidr: " 192.168.001.010/24 ", gateway: "192.168.1.001", dns: ["008.008.008.008"])
        #expect(value.address == "192.168.1.10")
        #expect(value.prefixLength == 24)
        #expect(value.gateway == "192.168.1.1")
        #expect(value.dns == ["8.8.8.8"])
        #expect(value.cidr == "192.168.1.10/24")
        try value.validate()
    }

    @Test func dnsDefaultsToGatewayAndMaskIsDotted() throws {
        let value = try StaticIPv4(cidr: "10.1.2.3/20", gateway: "10.1.0.1")
        #expect(value.dns.isEmpty)
        #expect(value.dnsServers == ["10.1.0.1"])
        #expect(value.subnetMask == "255.255.240.0")
        #expect(try StaticIPv4(cidr: "10.1.2.3/8", gateway: "10.0.0.1").subnetMask == "255.0.0.0")
        #expect(try StaticIPv4(cidr: "10.1.2.1/30", gateway: "10.1.2.2").subnetMask == "255.255.255.252")
        let withDNS = try StaticIPv4(cidr: "10.1.2.3/20", gateway: "10.1.0.1", dns: ["1.1.1.1", "9.9.9.9"])
        #expect(withDNS.dnsServers == ["1.1.1.1", "9.9.9.9"])
    }

    @Test func rejectsMalformedInput() {
        for cidr in ["192.168.1.10", "192.168.1.10/", "192.168.1/24", "192.168.1.10/abc", "192.168.1.256/24", "fe80::1/64", ""] {
            #expect(code { _ = try StaticIPv4(cidr: cidr, gateway: "192.168.1.1") } == "invalid_config", "\(cidr)")
        }
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "router") } == "invalid_config")
    }

    @Test func rejectsPrefixOutOfRange() {
        for prefix in [0, 7, 31, 32, 33] {
            #expect(code { _ = try StaticIPv4(cidr: "10.0.0.5/\(prefix)", gateway: "10.0.0.1") } == "invalid_config", "\(prefix)")
        }
    }

    @Test func rejectsGatewayOutsideSubnetOrEqualToAddress() {
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.2.1") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.10") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/23", gateway: "192.168.0.1") } == nil)
    }

    @Test func rejectsGatewayAtNetworkOrBroadcastAddress() {
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.0") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.255") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/23", gateway: "192.168.1.255") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/23", gateway: "192.168.0.255") } == nil)
    }

    @Test func rejectsNetworkAndBroadcastAddresses() {
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.0/24", gateway: "192.168.1.1") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.255/24", gateway: "192.168.1.1") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.255/23", gateway: "192.168.0.1") } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.0.255/23", gateway: "192.168.0.1") } == nil)
    }

    @Test func rejectsReservedAddresses() {
        for cidr in ["0.1.2.3/8", "127.0.0.2/8", "169.254.1.2/16", "224.0.0.5/8", "240.0.0.5/8"] {
            #expect(code { _ = try StaticIPv4(cidr: cidr, gateway: "\(cidr.prefix { $0 != "." }).0.0.1") } == "invalid_config", "\(cidr)")
        }
    }

    @Test func rejectsBadDNS() {
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1", dns: ["dns.google"]) } == "invalid_config")
        let four = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1", dns: four) } == "invalid_config")
        #expect(code { _ = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1", dns: Array(four.prefix(3))) } == nil)
    }

    @Test func validateRechecksDecodedValues() throws {
        var value = try StaticIPv4(cidr: "192.168.1.10/24", gateway: "192.168.1.1")
        value.address = "192.168.1.10; reboot"
        #expect(code { try value.validate() } == "invalid_config")
        // 前导零 `inet_pton` 放行，但客户机里的工具读法不一，存下的值必须是规范形式。
        value.address = "192.168.001.010"
        #expect(code { try value.validate() } == "invalid_config")
        value.address = "192.168.1.10"
        value.gateway = "192.168.1.01"
        #expect(code { try value.validate() } == "invalid_config")
        value.gateway = "192.168.1.1"
        value.prefixLength = 31
        #expect(code { try value.validate() } == "invalid_config")
        value.prefixLength = 24
        value.dns = ["1.1.1.1", "1.1.1.1", "1.1.1.1", "1.1.1.1"]
        #expect(code { try value.validate() } == "invalid_config")
    }

    @Test func ipv4Helpers() {
        #expect(IPv4.parse("192.168.1.10") == 0xC0A8_010A)
        #expect(IPv4.parse(" 192.168.1.10") == nil)
        #expect(IPv4.format(0xC0A8_010A) == "192.168.1.10")
        #expect(IPv4.mask(prefix: 0) == 0)
        #expect(IPv4.mask(prefix: 24) == 0xFFFF_FF00)
        #expect(IPv4.mask(prefix: 32) == 0xFFFF_FFFF)
    }
}
