import Foundation
import MacVMModel
import Security

// macvm-netd：由 launchd 按需以 root 启动，没有连接一段时间后自行退出，下次有连接时 launchd 再拉起。
// 退出后 launchd 拉起的是 App 里当前的二进制，App 升级后不会一直跑着旧版本。

final class Session: NSObject, NetworkHelperService, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "macvm.netd.session")
    private var bridge: Bridge?

    init(connection: NSXPCConnection) { self.connection = connection }

    func ping(reply: @escaping @Sendable ([String]) -> Void) { reply(Bridge.interfaces()) }

    func openBridge(interface: String, macAddress: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void) {
        queue.async { [self] in
            guard bridge == nil else { return reply(nil, "这条连接上已经建过桥接") }
            guard let mac = ARPSnoop.parseMAC(macAddress) else { return reply(nil, "MAC 地址无效：\(macAddress)") }
            let available = Bridge.interfaces()
            guard available.contains(interface) else {
                return reply(nil, "\(interface) 不能桥接，可用：\(available.joined(separator: ", "))")
            }
            let client = connection?.remoteObjectProxy as? any NetworkHelperClient
            let proxy = UncheckedClient(value: client)
            do throws(Bridge.Failure) {
                let (bridge, fd) = try Bridge.start(interface: interface, mac: mac) { proxy.value?.guestAddressChanged($0) }
                self.bridge = bridge
                // XPC 发送时复制一份描述符，本端随句柄释放而关闭。
                reply(FileHandle(fileDescriptor: fd, closeOnDealloc: true), nil)
            } catch {
                reply(nil, error.message)
            }
        }
    }

    func close() {
        queue.async { [self] in
            bridge?.stop()
            bridge = nil
        }
    }
}

private struct UncheckedClient: @unchecked Sendable { let value: (any NetworkHelperClient)? }

/// 最后一条连接断开 `idleTimeout` 后仍没有新连接就退出。
final class IdleExit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macvm.netd.idle")
    private var connections = 0
    private var generation = 0
    private static let idleTimeout: DispatchTimeInterval = .seconds(30)

    func retain() { queue.async { [self] in connections += 1; generation += 1 } }

    func release() { queue.async { [self] in connections -= 1; scheduleIfIdle() } }

    func scheduleIfIdle() {
        guard connections == 0 else { return }
        generation += 1
        let armed = generation
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) { [self] in
            if connections == 0, generation == armed { exit(0) }
        }
    }

    func start() { queue.async { [self] in scheduleIfIdle() } }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let idle = IdleExit()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 每条连接现取要求：开发时 App 重新构建后 cdhash 就变了，守护进程却可能还没退出。
        connection.setCodeSigningRequirement(clientRequirement())
        let session = Session(connection: connection)
        connection.exportedInterface = NetworkHelper.serviceInterface()
        connection.exportedObject = session
        connection.remoteObjectInterface = NetworkHelper.clientInterface()
        let idle = idle
        connection.invalidationHandler = {
            session.close()
            idle.release()
        }
        idle.retain()
        connection.resume()
        return true
    }
}

/// 只接受与本程序同在一个 App 包里的 App 主程序与 `macvm` CLI：取它们各自的指定要求（designated requirement），
/// 正式签名时固定 identifier 与 Team ID，ad-hoc 签名时固定 cdhash。一个也取不到时拒绝所有连接。
func clientRequirement() -> String {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var path: CFURL?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path
    else { return "never" }
    var app = (path as URL).standardizedFileURL
    while app.pathExtension != "app" {
        guard app.pathComponents.count > 1 else { return "never" }
        app.deleteLastPathComponent()
    }
    let requirements = [app, app.appending(path: "Contents/Resources/bin/macvm")].compactMap(designatedRequirement(of:))
    return requirements.isEmpty ? "never" : requirements.map { "(\($0))" }.joined(separator: " or ")
}

func designatedRequirement(of url: URL) -> String? {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var text: CFString?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
    else { return nil }
    return text as String
}

// 引擎那端关闭后往 socket 发帧会收到 SIGPIPE，默认处理会让整个守护进程退出、拆掉所有桥接。
signal(SIGPIPE, SIG_IGN)
let listener = NSXPCListener(machServiceName: NetworkHelper.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
delegate.idle.start()
dispatchMain()
