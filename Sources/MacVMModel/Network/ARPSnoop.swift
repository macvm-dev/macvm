/// 从客户机发出的以太网帧里认出它的 IPv4 地址：桥接时地址由局域网的 DHCP 分配，主机上查不到租约。
/// 只看 ARP：客户机拿到地址后会发 ARP 宣告，此后也会定期 ARP 网关；它发出的 IP 包源地址可能是它转发的别人。
public enum ARPSnoop {
    /// 解析 `xx:xx:xx:xx:xx:xx`；格式不对时为 nil。
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        return bytes.count == 6 ? bytes : nil
    }

    /// `frame` 是 `mac` 发出、宣告自己 IPv4 地址的 ARP 时返回该地址。
    /// 不算探测（发送方地址为 0）与链路本地地址（169.254/16，DHCP 失败时客户机自己挑的）。
    public static func senderAddress(in frame: UnsafeRawBufferPointer, from mac: [UInt8]) -> String? {
        let ethernetHeader = 14, arpLength = 28
        guard mac.count == 6, frame.count >= ethernetHeader + arpLength else { return nil }
        func u16(_ offset: Int) -> UInt16 { UInt16(frame[offset]) << 8 | UInt16(frame[offset + 1]) }
        guard frame[6..<12].elementsEqual(mac), u16(12) == 0x0806 else { return nil }
        let arp = ethernetHeader
        // 硬件类型以太网、协议类型 IPv4、地址长度 6 与 4。
        guard u16(arp) == 1, u16(arp + 2) == 0x0800, frame[arp + 4] == 6, frame[arp + 5] == 4 else { return nil }
        guard frame[(arp + 8)..<(arp + 14)].elementsEqual(mac) else { return nil }
        let ip = Array(frame[(arp + 14)..<(arp + 18)])
        guard ip != [0, 0, 0, 0], !(ip[0] == 169 && ip[1] == 254) else { return nil }
        return ip.map(String.init).joined(separator: ".")
    }
}
