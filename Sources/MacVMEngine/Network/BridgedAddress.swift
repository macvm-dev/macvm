import Foundation
import MacVMModel

/// 桥接网络下客户机的地址由局域网分配，宿主的 DHCP 租约里没有：运行虚拟机的进程经代理 `info` 取客户机的 IPv4，
/// 写进 `VMBundle.bridgedAddressURL` 给 `GuestAddress` 读。
enum BridgedAddress {
    /// 主机字节序的 IPv4 地址与掩码。
    typealias Subnet = (address: UInt32, mask: UInt32)

    /// 从客户机报的地址里挑一个：先挑落在 `hostSubnets` 里的，客户机里 Docker 之类的内部网段排在后面；
    /// 没有时取第一个不是链路本地（169.254/16）的地址。
    static func pick(_ guest: [String], hostSubnets: [Subnet]) -> String? {
        let parsed = guest.compactMap { text in ipv4(text).map { (text: text, value: $0) } }
        if let match = parsed.first(where: { entry in hostSubnets.contains { entry.value & $0.mask == $0.address & $0.mask } }) {
            return match.text
        }
        return parsed.first { $0.value & 0xFFFF_0000 != 0xA9FE_0000 }?.text
    }

    /// 宿主网卡 `bsdName` 上的 IPv4 网段。
    static func hostSubnets(of bsdName: String) -> [Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var subnets: [Subnet] = []
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard String(cString: entry.ifa_name) == bsdName,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            subnets.append((inAddr(address), inAddr(mask)))
        }
        return subnets
    }

    /// 桥接、装有代理的 Linux / macOS 客户机开机后，在后台定时取客户机地址，有变化才写入 `VMBundle.bridgedAddressURL`；
    /// 其他情况返回 nil。先删掉上次运行留下的文件。阻塞的 socket 往返都在后台任务里，任务取消后不再写入。
    static func watch(_ bundle: VMBundle, config: VMConfig) -> Task<Void, Never>? {
        clear(bundle)
        guard let net = config.networks.first, net.mode == .bridged, config.guestAgent, config.os != .windows else { return nil }
        let interface = net.interface
        return Task.detached {
            var written: String?
            while !Task.isCancelled {
                if let info = try? AgentClient.info(bundle, timeout: infoTimeout), !Task.isCancelled {
                    let address = pick(info.ipv4, hostSubnets: interface.map(hostSubnets(of:)) ?? [])
                    if address != written, store(address, for: bundle) { written = address }
                }
                try? await Task.sleep(for: written == nil ? retryInterval : refreshInterval)
            }
        }
    }

    static func clear(_ bundle: VMBundle) {
        try? FileManager.default.removeItem(at: bundle.bridgedAddressURL)
    }

    /// 原子写入，读的一方不会读到半截；`address` 为 nil 时删除文件。返回是否成功。
    private static func store(_ address: String?, for bundle: VMBundle) -> Bool {
        guard let address else {
            clear(bundle)
            return !FileManager.default.fileExists(atPath: bundle.bridgedAddressURL.path)
        }
        return (try? Data((address + "\n").utf8).write(to: bundle.bridgedAddressURL, options: .atomic)) != nil
    }

    /// 还没取到地址时的重试间隔：代理在客户机登录后才上线。
    private static let retryInterval: Duration = .seconds(3)
    /// 取到地址之后的刷新间隔，跟上客户机续租或换网后的新地址。
    private static let refreshInterval: Duration = .seconds(30)
    private static let infoTimeout = 3

    static func ipv4(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// 只拷 `sa_len` 字节：内核给的掩码 sockaddr 可能比 `sockaddr_in` 短，缺的部分按零算。
    private static func inAddr(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        var sin = sockaddr_in()
        let length = min(Int(pointer.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &sin) { $0.copyMemory(from: UnsafeRawBufferPointer(start: pointer, count: length)) }
        return UInt32(bigEndian: sin.sin_addr.s_addr)
    }
}
