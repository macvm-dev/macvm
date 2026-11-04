import Darwin
import Dispatch
import MacVMModel
import vmnet

/// 一块 vmnet 桥接接口与一对 `SOCK_DGRAM` socket 之间的双向转发：一端留在这里，另一端交给引擎。
/// 全部状态只在 `queue` 上读写；vmnet 的回调也派到这个队列。
final class Bridge: @unchecked Sendable {
    struct Failure: Error { let message: String }

    private let interface: interface_ref
    private let socket: Int32
    private let queue: DispatchQueue
    private let mac: [UInt8]
    private let onAddress: @Sendable (String) -> Void
    private let packetSize: Int
    private let packets: PacketBuffers
    private var readSource: (any DispatchSourceRead)?
    private var lastAddress: String?
    private var stopped = false

    /// 每次 `vmnet_read`、`vmnet_write` 最多处理的帧数。
    private static let batch = 32
    private static let sendBuffer = 1 << 20
    /// VZ 要求收缓冲不小于发缓冲的两倍，建议四倍。
    private static let receiveBuffer = 4 << 20

    /// 主机上可桥接的网卡（BSD 名）。
    static func interfaces() -> [String] {
        guard let list = vmnet_copy_shared_interface_list() else { return [] }
        return (0..<xpc_array_get_count(list)).compactMap { i in
            xpc_array_get_string(list, i).map { String(cString: $0) }
        }
    }

    /// 建桥接并返回交给引擎的那端 socket，调用方负责关闭它。
    static func start(interface name: String, mac: [UInt8], onAddress: @escaping @Sendable (String) -> Void) throws(Failure) -> (Bridge, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { throw Failure(message: "socketpair：\(String(cString: strerror(errno)))") }
        for fd in fds {
            var send = Int32(sendBuffer), receive = Int32(receiveBuffer)
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)

        let queue = DispatchQueue(label: "macvm.netd.\(name)")
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, name)
        // 客户机用配置里自己的 MAC 地址。
        xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false)

        let started = StartResult()
        let done = DispatchSemaphore(value: 0)
        let iface = vmnet_start_interface(desc, queue) { status, params in
            started.status = status
            if let params { started.maxPacketSize = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key)) }
            done.signal()
        }
        guard let iface else {
            close(fds[0]); close(fds[1])
            throw Failure(message: "vmnet 桥接 \(name) 失败")
        }
        guard done.wait(timeout: .now() + 10) == .success, started.status == .VMNET_SUCCESS else {
            // 超时后接口仍可能建起来，不停掉就一直占着。
            vmnet_stop_interface(iface, queue) { _ in }
            close(fds[0]); close(fds[1])
            throw Failure(message: "vmnet 桥接 \(name) 失败（\(started.status.map { "\($0.rawValue)" } ?? "超时")）")
        }
        let bridge = Bridge(interface: iface, socket: fds[0], queue: queue, mac: mac,
                            packetSize: max(started.maxPacketSize, 1514), onAddress: onAddress)
        queue.sync { bridge.activate() }
        return (bridge, fds[1])
    }

    private init(interface: interface_ref, socket: Int32, queue: DispatchQueue, mac: [UInt8], packetSize: Int, onAddress: @escaping @Sendable (String) -> Void) {
        self.interface = interface
        self.socket = socket
        self.queue = queue
        self.mac = mac
        self.packetSize = packetSize
        self.onAddress = onAddress
        packets = PacketBuffers(count: Self.batch, size: packetSize)
    }

    private func activate() {
        vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
            self?.forwardFromNetwork()
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.forwardFromGuest() }
        source.setCancelHandler { [socket] in close(socket) }
        source.resume()
        readSource = source
    }

    /// 拆掉桥接并关闭本端 socket。可重复调用。
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            readSource?.cancel()
            vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
            // 回调持有 self，接口停下之前缓冲区不能释放。
            vmnet_stop_interface(interface, queue) { _ in _ = self }
        }
    }

    /// 网卡 → 客户机。对端收缓冲满时丢帧，和网线上一样交给上层重传。
    private func forwardFromNetwork() {
        guard !stopped else { return }
        while true {
            packets.reset()
            var count = Int32(Self.batch)
            guard vmnet_read(interface, packets.descriptors, &count) == .VMNET_SUCCESS, count > 0 else { return }
            for i in 0..<Int(count) {
                _ = send(socket, packets.base(i), packets.descriptors[i].vm_pkt_size, 0)
            }
            if count < Int32(Self.batch) { return }
        }
    }

    /// 客户机 → 网卡，顺带从 ARP 里认客户机的地址。
    private func forwardFromGuest() {
        guard !stopped else { return }
        while true {
            var count = 0
            while count < Self.batch {
                let n = recv(socket, packets.base(count), packetSize, 0)
                if n < 0, errno == EAGAIN || errno == EINTR { break }
                // 两端都不发空数据报，读到 0 字节或出错是对端已关闭；不停掉读源会一直被唤醒。
                if n <= 0 { readSource?.cancel(); break }
                packets.setLength(count, n)
                if let ip = ARPSnoop.senderAddress(in: UnsafeRawBufferPointer(start: packets.base(count), count: n), from: mac), ip != lastAddress {
                    lastAddress = ip
                    onAddress(ip)
                }
                count += 1
            }
            guard count > 0 else { return }
            var written = Int32(count)
            _ = vmnet_write(interface, packets.descriptors, &written)
            if count < Self.batch { return }
        }
    }
}

private final class StartResult: @unchecked Sendable {
    var status: vmnet_return_t?
    var maxPacketSize = 0
}

/// `count` 个各 `size` 字节的帧缓冲与指向它们的 `vmpktdesc`。
private final class PacketBuffers {
    let descriptors: UnsafeMutablePointer<vmpktdesc>
    private let iovecs: UnsafeMutablePointer<iovec>
    private let storage: UnsafeMutableRawPointer
    private let count: Int
    private let size: Int

    init(count: Int, size: Int) {
        self.count = count
        self.size = size
        storage = .allocate(byteCount: count * size, alignment: 16)
        iovecs = .allocate(capacity: count)
        descriptors = .allocate(capacity: count)
        for i in 0..<count {
            iovecs[i] = iovec(iov_base: storage + i * size, iov_len: size)
            descriptors[i] = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovecs + i, vm_pkt_iovcnt: 1, vm_flags: 0)
        }
    }

    deinit {
        storage.deallocate()
        iovecs.deallocate()
        descriptors.deallocate()
    }

    func base(_ i: Int) -> UnsafeMutableRawPointer { storage + i * size }

    /// `vmnet_read` 读之前每块都要恢复成满长度。
    func reset() {
        for i in 0..<count { setLength(i, size) }
    }

    func setLength(_ i: Int, _ length: Int) {
        iovecs[i].iov_len = length
        descriptors[i].vm_pkt_size = length
        descriptors[i].vm_flags = 0
    }
}
