import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct PortForwarderTests {
    /// 本机上一个回显服务，返回端口；`accepts` 个连接之后关闭。
    func echoServer(accepts: Int = 1) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        Thread.detachNewThread {
            for _ in 0..<accepts {
                let client = accept(fd, nil, nil)
                var buf = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = read(client, &buf, buf.count)
                    if n <= 0 { break }
                    _ = write(client, buf, n)
                }
                close(client)
            }
            close(fd)
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// 宿主上一个空闲端口。
    func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    @Test func forwardsBytesBothWays() throws {
        let echo = try echoServer()
        let forwarder = PortForwarder(dial: { _ in GuestConnection.tcpConnect("127.0.0.1", echo) }, onError: { _, _ in })
        defer { forwarder.close() }
        let forward = PortForward(hostPort: freePort(), guestPort: 80)
        #expect(forwarder.apply([forward]).isEmpty)
        let fd = GuestConnection.tcpConnect("127.0.0.1", forward.hostPort)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(write(fd, "ping", 4) == 4)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(read(fd, &buf, 4) == 4)
        #expect(buf == Array("ping".utf8))
    }

    @Test func failedDialResetsAndReports() throws {
        let reported = Locked<[UInt16]>([])
        let forwarder = PortForwarder(dial: { _ in throw MacVMError.io("no guest") }, onError: { forward, _ in reported.mutate { $0.append(forward.guestPort) } })
        defer { forwarder.close() }
        let forward = PortForward(hostPort: freePort(), guestPort: 81)
        #expect(forwarder.apply([forward]).isEmpty)
        let fd = GuestConnection.tcpConnect("127.0.0.1", forward.hostPort)
        try #require(fd >= 0)
        defer { close(fd) }
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) <= 0)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(reported.value == [81])
    }

    @Test func reconcilesAndReportsBusyPorts() throws {
        let forwarder = PortForwarder(dial: { _ in -1 }, onError: { _, _ in })
        defer { forwarder.close() }
        let port = freePort()
        #expect(forwarder.apply([PortForward(hostPort: port, guestPort: 80)]).isEmpty)
        // 同一宿主端口换客户机端口：先停旧的再监听新的，不报占用。
        #expect(forwarder.apply([PortForward(hostPort: port, guestPort: 81)]).isEmpty)
        #expect(forwarder.active == [PortForward(hostPort: port, guestPort: 81)])

        let other = PortForwarder(dial: { _ in -1 }, onError: { _, _ in })
        defer { other.close() }
        let failures = other.apply([PortForward(hostPort: port, guestPort: 80)])
        #expect(failures.count == 1 && failures.first?.1.code == "io")

        forwarder.apply([])
        #expect(GuestConnection.tcpConnect("127.0.0.1", port) < 0)
    }

    @Test func refusesPortHeldOnAnyAddress() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let forwarder = PortForwarder(dial: { _ in -1 }, onError: { _, _ in })
        defer { forwarder.close() }
        let failures = forwarder.apply([PortForward(hostPort: UInt16(bigEndian: addr.sin_port), guestPort: 80)])
        #expect(failures.count == 1 && failures.first?.1.code == "io")
    }

    @Test func rebindsWhileConnectionsStayOpen() throws {
        let echo = try echoServer()
        let forwarder = PortForwarder(dial: { _ in GuestConnection.tcpConnect("127.0.0.1", echo) }, onError: { _, _ in })
        defer { forwarder.close() }
        let port = freePort()
        #expect(forwarder.apply([PortForward(hostPort: port, guestPort: 80)]).isEmpty)
        let fd = GuestConnection.tcpConnect("127.0.0.1", port)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(write(fd, "ping", 4) == 4)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(read(fd, &buf, 4) == 4)
        // 已建立的连接仍占着这个端口。
        #expect(forwarder.apply([PortForward(hostPort: port, guestPort: 81)]).isEmpty)
    }
}

/// 测试里跨线程收集结果。
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

struct DHCPLeasesTests {
    let sample = """
    {
    	name=old
    	ip_address=192.168.64.2
    	hw_address=1,2:0:0:a:b:c
    	lease=0x60000000
    }
    {
    	name=new
    	ip_address=192.168.64.9
    	hw_address=1,2:0:0:a:b:c
    	lease=0x70000000
    }
    {
    	name=other
    	ip_address=192.168.64.3
    	hw_address=1,2:0:0:a:b:d
    	lease=0x70000000
    }
    """

    @Test func picksNewestLeaseForPaddedMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0c", in: sample) == "192.168.64.9")
    }

    @Test func fallsBackToHostnameForDUIDClients() {
        let duid = sample + """

        {
        	name=deb
        	ip_address=192.168.64.20
        	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11
        	lease=0x70000000
        }
        """
        let beforeExpiry = Date(timeIntervalSince1970: 0x6FFF_FFFF)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: beforeExpiry) == "192.168.64.20")
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: Date(timeIntervalSince1970: 0x7000_0001)) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "DEB", in: duid, now: beforeExpiry) == "192.168.64.20")
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", in: duid) == nil)
    }

    @Test func unknownMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0e", in: sample) == nil)
    }
}

struct GuestAddressTests {
    @Test func bridgedReadsAddressFileAndNATReadsLeases() throws {
        try RuntimeDirectory.ensure()
        let bundle = VMBundle(url: URL(filePath: "/vms/guest-address-test-\(UUID().uuidString).macvm"))
        var config = VMConfig(name: bundle.name, os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [],
                              networks: [NetworkConfig(mode: .bridged, interface: "en0", macAddress: "02:00:00:0a:0b:0c")])
        defer { BridgedAddress.clear(bundle) }
        let noLeases: () -> String? = { Issue.record("桥接不该读租约"); return nil }
        #expect(GuestAddress.current(bundle, config, leases: noLeases) == nil)
        try Data("192.168.1.23\n".utf8).write(to: bundle.bridgedAddressURL)
        #expect(GuestAddress.current(bundle, config, leases: noLeases) == "192.168.1.23")
        try Data("-oProxyCommand=x\n".utf8).write(to: bundle.bridgedAddressURL)
        #expect(GuestAddress.current(bundle, config, leases: noLeases) == nil)

        try config.setNetwork(.nat)
        let leases = "{\n\tname=x\n\tip_address=192.168.64.5\n\thw_address=1,2:0:0:a:b:c\n\tlease=0x70000000\n}"
        #expect(GuestAddress.current(bundle, config) { leases } == "192.168.64.5")
        #expect(GuestAddress.current(bundle, config) { nil } == nil)
    }

    @Test func bridgedWithStaticAddressStillReadsAddressFile() throws {
        try RuntimeDirectory.ensure()
        let bundle = VMBundle(url: URL(filePath: "/vms/guest-address-static-\(UUID().uuidString).macvm"))
        defer { BridgedAddress.clear(bundle) }
        let fixed = try StaticIPv4(cidr: "192.168.1.50/24", gateway: "192.168.1.1")
        var config = VMConfig(name: bundle.name, os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [],
                              networks: [NetworkConfig(mode: .bridged, interface: "en0", macAddress: "02:00:00:0a:0b:0c", staticIPv4: fixed)])
        config.guestStaticIPv4 = fixed
        let noLeases: () -> String? = { Issue.record("桥接不该读租约"); return nil }
        #expect(GuestAddress.current(bundle, config, leases: noLeases) == nil)
        BridgedAddress.store("192.168.1.50", for: bundle)
        #expect(GuestAddress.current(bundle, config, leases: noLeases) == "192.168.1.50")
    }
}

struct BridgedAddressTests {
    let lan: [BridgedAddress.Subnet] = [(IPv4.parse("192.168.1.10")!, IPv4.parse("255.255.255.0")!)]

    @Test func prefersAddressInHostSubnet() {
        #expect(BridgedAddress.pick(["169.254.3.4", "172.17.0.1", "192.168.1.23"], hostSubnets: lan) == "192.168.1.23")
    }

    @Test func fallsBackToFirstNonLinkLocal() {
        #expect(BridgedAddress.pick(["169.254.3.4", "10.0.0.7", "172.17.0.1"], hostSubnets: []) == "10.0.0.7")
        #expect(BridgedAddress.pick(["169.254.3.4", "not-an-ip"], hostSubnets: lan) == nil)
        #expect(BridgedAddress.pick([], hostSubnets: lan) == nil)
    }

    @Test func preferredAddressWinsOnlyWhenGuestReportsIt() {
        let guest = ["172.17.0.1", "192.168.1.23", "192.168.1.50"]
        #expect(BridgedAddress.pick(guest, hostSubnets: lan, preferred: "192.168.1.50") == "192.168.1.50")
        #expect(BridgedAddress.pick(guest, hostSubnets: [], preferred: "172.17.0.1") == "172.17.0.1")
        #expect(BridgedAddress.pick(guest, hostSubnets: lan, preferred: "192.168.1.99") == "192.168.1.23")
        #expect(BridgedAddress.pick(guest, hostSubnets: lan, preferred: nil) == "192.168.1.23")
    }

    @Test func appliedStaticAddressNeedsMatchingRecord() throws {
        let fixed = try StaticIPv4(cidr: "192.168.1.50/24", gateway: "192.168.1.1")
        var config = VMConfig(name: "vm", os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [],
                              networks: [NetworkConfig(mode: .bridged, interface: "en0", macAddress: "02:00:00:0a:0b:0c", staticIPv4: fixed)])
        #expect(BridgedAddress.appliedStaticAddress(in: config) == nil)
        config.guestStaticIPv4 = try StaticIPv4(cidr: "192.168.1.60/24", gateway: "192.168.1.1")
        #expect(BridgedAddress.appliedStaticAddress(in: config) == nil)
        config.guestStaticIPv4 = fixed
        #expect(BridgedAddress.appliedStaticAddress(in: config) == "192.168.1.50")
    }

    @Test func storedIgnoresNonIPv4Content() throws {
        try RuntimeDirectory.ensure()
        let bundle = VMBundle(url: URL(filePath: "/vms/bridged-stored-\(UUID().uuidString).macvm"))
        defer { BridgedAddress.clear(bundle) }
        #expect(BridgedAddress.stored(for: bundle) == nil)
        #expect(BridgedAddress.store("192.168.1.23", for: bundle))
        #expect(BridgedAddress.stored(for: bundle) == "192.168.1.23")
        try Data("-oProxyCommand=x\n".utf8).write(to: bundle.bridgedAddressURL)
        #expect(BridgedAddress.stored(for: bundle) == nil)
        #expect(BridgedAddress.store(nil, for: bundle))
        #expect(!FileManager.default.fileExists(atPath: bundle.bridgedAddressURL.path))
    }
}
