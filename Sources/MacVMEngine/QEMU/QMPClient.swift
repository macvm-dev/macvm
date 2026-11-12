import Foundation
import MacVMModel

/// QEMU Machine Protocol 客户端：一条连接，命令按序应答，事件交给 `onEvent`。
final class QMPClient: @unchecked Sendable {
    typealias JSON = [String: Any]

    private let socket: UnixSocket
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Unchecked<Any>, any Error>] = []
    private var closed = false
    var onEvent: (@Sendable (String, JSON) -> Void)?

    private init(socket: UnixSocket) { self.socket = socket }

    /// QEMU 启动后 socket 才出现，所以在超时内重试连接；等问候语也算在超时内。
    static func connect(to path: String, timeout: TimeInterval, isAlive: @Sendable () -> Bool) async throws -> QMPClient {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let socket = try? UnixSocket.connect(to: path) {
                let client = QMPClient(socket: socket)
                // QEMU 先监听，主循环起来后才接受连接、发问候语，初始化卡住时读会一直阻塞。
                socket.setTimeout(seconds: max(1, Int(deadline.timeIntervalSinceNow.rounded(.up))))
                guard (try? socket.readLine()) != nil else {
                    guard isAlive() else { throw MacVMError.engine(String(l10n: "QEMU quit right after starting")) }
                    throw MacVMError.timeout(String(l10n: "Timed out connecting to the QEMU control interface"))
                }
                socket.setTimeout(seconds: 0)
                Thread.detachNewThread { client.readLoop() }
                _ = try await client.execute("qmp_capabilities")
                return client
            }
            guard isAlive() else { throw MacVMError.engine(String(l10n: "QEMU quit right after starting")) }
            guard Date() < deadline else { throw MacVMError.timeout(String(l10n: "Timed out connecting to the QEMU control interface")) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    func execute(_ command: String, _ arguments: JSON? = nil) async throws -> JSON {
        try await send(command, arguments) as? JSON ?? [:]
    }

    /// 经 `human-monitor-command` 执行一条 HMP 命令。HMP 命令出错时 QMP 照样成功，错误在返回的文字里，所以非空即报错。
    func human(_ commandLine: String) async throws {
        let output = (try await send("human-monitor-command", ["command-line": commandLine]) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.isEmpty else { throw MacVMError.engine(String(l10n: "QEMU: \(output)")) }
    }

    private func send(_ command: String, _ arguments: JSON?) async throws -> Any {
        var message: JSON = ["execute": command]
        if let arguments { message["arguments"] = arguments }
        let data = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked<Any>, any Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume(throwing: MacVMError.notRunning(String(l10n: "QEMU has exited")))
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
                c?.resume(throwing: MacVMError.engine(String(l10n: "QEMU: \(error["desc"] as? String ?? String(l10n: "Unknown error"))")))
            } else {
                c?.resume(returning: Unchecked(value: object["return"] ?? JSON()))
            }
        }
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume(throwing: MacVMError.notRunning(String(l10n: "QEMU has exited"))) }
    }
}
