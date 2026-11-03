import Foundation
import MacVMModel

/// QEMU Machine Protocol 客户端：一条连接，命令按序应答，事件交给 `onEvent`。
final class QMPClient: @unchecked Sendable {
    typealias JSON = [String: Any]

    private let socket: UnixSocket
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Unchecked<JSON>, any Error>] = []
    private var closed = false
    var onEvent: (@Sendable (String, JSON) -> Void)?

    private init(socket: UnixSocket) { self.socket = socket }

    /// QEMU 启动后 socket 才出现，所以在超时内重试连接。
    static func connect(to path: String, timeout: TimeInterval, isAlive: @Sendable () -> Bool) async throws -> QMPClient {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let socket = try? UnixSocket.connect(to: path) {
                let client = QMPClient(socket: socket)
                _ = try socket.readLine()
                Thread.detachNewThread { client.readLoop() }
                _ = try await client.execute("qmp_capabilities")
                return client
            }
            guard isAlive() else { throw MacVMError.engine("QEMU 启动后立即退出") }
            guard Date() < deadline else { throw MacVMError.timeout("连接 QEMU 控制接口超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    func execute(_ command: String, _ arguments: JSON? = nil) async throws -> JSON {
        var message: JSON = ["execute": command]
        if let arguments { message["arguments"] = arguments }
        let data = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<JSON>, any Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume(throwing: MacVMError.notRunning("QEMU 已退出"))
                return
            }
            pending.append(c)
            do {
                try socket.writeLine(data)
                lock.unlock()
            } catch {
                pending.removeLast()
                lock.unlock()
                c.resume(throwing: error)
            }
        }.value
    }

    private func readLoop() {
        while let line = try? socket.readLine() {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
            if let event = object["event"] as? String {
                onEvent?(event, object["data"] as? JSON ?? [:])
                continue
            }
            lock.lock()
            let c = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            if let error = object["error"] as? JSON {
                c?.resume(throwing: MacVMError.engine("QEMU：\(error["desc"] as? String ?? "未知错误")"))
            } else {
                c?.resume(returning: Unchecked(value: object["return"] as? JSON ?? [:]))
            }
        }
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume(throwing: MacVMError.notRunning("QEMU 已退出")) }
    }
}
