public import Foundation
public import MacVMModel

/// 经网络辅助程序 macvm-netd 的一条桥接。XPC 连接在则桥接在，`close` 或释放后辅助进程拆掉它。
/// 辅助进程从客户机的 ARP 里认出的地址写进 `VMBundle.bridgedAddressURL`，供别的进程查 IP。
/// 打开时不碰这个文件：打开它的进程可能拿不到包锁，文件属于正在运行的那一个。
final class BridgeSession: @unchecked Sendable {
    /// 交给引擎的 `SOCK_DGRAM` socket，每个数据报是一个以太网帧。
    let fileHandle: FileHandle
    private let connection: NSXPCConnection
    private let sink: AddressSink

    /// 等辅助进程回应的最长时间；它要先由 launchd 拉起，再建 vmnet 接口。
    private static let openTimeout: TimeInterval = 20

    static var unavailableError: MacVMError {
        .unsupported(String(l10n: "Bridged networking needs the network helper. Turn it on in MacVM Settings; the first time, also allow MacVM in System Settings › General › Login Items & Extensions."))
    }

    static var unresponsiveError: MacVMError {
        .timeout(String(l10n: "The network helper isn't responding; turn it off and on again in MacVM Settings"))
    }

    private init(fileHandle: FileHandle, connection: NSXPCConnection, sink: AddressSink) {
        self.fileHandle = fileHandle
        self.connection = connection
        self.sink = sink
    }

    deinit { close() }

    /// `net.interface` 为空时桥接到第一块可桥接的网卡。
    static func open(_ net: NetworkConfig, bundle: VMBundle) throws -> BridgeSession {
        guard let mac = net.macAddress else { throw MacVMError.invalidConfig(String(l10n: "Bridged networking needs a fixed MAC address")) }
        let interface = try NetworkAttachments.bridgeInterface(named: net.interface)
        try? RuntimeDirectory.ensure()
        let sink = AddressSink(url: bundle.bridgedAddressURL)
        let connection = connect(exporting: sink)
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            reply.unavailable = true
            done.signal()
        } as? any NetworkHelperService
        proxy?.openBridge(interface: interface, macAddress: mac) { handle, message in
            reply.handle = handle
            reply.message = message
            done.signal()
        }
        guard done.wait(timeout: .now() + openTimeout) == .success else {
            connection.invalidate()
            throw unresponsiveError
        }
        guard let handle = reply.handle else {
            connection.invalidate()
            if reply.unavailable { throw unavailableError }
            throw MacVMError.engine(String(l10n: "Couldn't bridge to \(interface): \(reply.message ?? String(l10n: "unknown reason"))"))
        }
        return BridgeSession(fileHandle: handle, connection: connection, sink: sink)
    }

    /// 删掉上次运行留下的地址文件。只能由持有包锁的运行器在开机前调用。
    static func clearAddress(of bundle: VMBundle) {
        try? FileManager.default.removeItem(at: bundle.bridgedAddressURL)
    }

    /// 在后台依次打开 `config` 里所有桥接网卡的桥接，顺序与网卡相同：打开要等辅助进程，可能要几秒。
    static func openAll(for config: VMConfig, bundle: VMBundle) async throws -> [BridgeSession] {
        let nets = config.networks.filter { $0.mode == .bridged }
        guard !nets.isEmpty else { return [] }
        return try await Task.detached { try nets.map { try open($0, bundle: bundle) } }.value
    }

    /// 辅助进程在运行时返回它看到的可桥接网卡；未启用、未获允许或没响应时为 nil。
    static func ping(timeout: TimeInterval = 2) -> [String]? {
        let connection = connect(exporting: nil)
        defer { connection.invalidate() }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? any NetworkHelperService
        proxy?.ping { interfaces in
            reply.interfaces = interfaces
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return reply.interfaces
    }

    private static func connect(exporting sink: AddressSink?) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: NetworkHelper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NetworkHelper.serviceInterface()
        if let sink {
            connection.exportedInterface = NetworkHelper.clientInterface()
            connection.exportedObject = sink
        }
        connection.resume()
        return connection
    }

    /// 拆掉桥接；本条桥接写过地址文件时删掉它。可重复调用。
    func close() {
        connection.invalidate()
        sink.close()
    }

    private final class Reply: @unchecked Sendable {
        var handle: FileHandle?
        var message: String?
        var unavailable = false
        var interfaces: [String]?
    }
}

extension MacVMError {
    /// 网络辅助程序未启用、未获允许或没有响应，要到 MacVM 设置的网络辅助程序一栏处理。
    public var needsNetworkHelperSettings: Bool {
        self == BridgeSession.unavailableError || self == BridgeSession.unresponsiveError
    }
}

/// 收辅助进程认出的客户机地址，写进文件。关闭后不再写：连接作废前已在路上的消息仍可能送到。
private final class AddressSink: NSObject, NetworkHelperClient, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var closed = false
    private var wrote = false

    init(url: URL) { self.url = url }

    func guestAddressChanged(_ address: String) {
        lock.withLock {
            guard !closed else { return }
            wrote = (try? Data(address.utf8).write(to: url, options: .atomic)) != nil || wrote
        }
    }

    func close() {
        lock.withLock {
            closed = true
            if wrote { try? FileManager.default.removeItem(at: url) }
        }
    }
}
