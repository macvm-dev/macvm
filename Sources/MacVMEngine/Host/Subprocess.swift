import Foundation
import MacVMModel
import Synchronization

enum Subprocess {
    /// 运行外部命令并等待结束，退出码不在 `acceptedExitCodes` 里时报错，把 stderr 带进错误信息。
    /// 给了 `stdout` 时输出直接写进它，返回空串。
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], passthroughStderr: Bool = false, stdin: URL? = nil,
                    stdout output: FileHandle? = nil, acceptedExitCodes: Set<Int32> = [0]) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = output ?? stdout
        process.standardError = passthroughStderr ? FileHandle.standardError : stderr
        process.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        try Task.checkCancellation()
        let running = RunningProcess(process)
        ChildProcesses.register(running)
        defer { ChildProcesses.unregister(running) }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Int32, Data, Data), any Error>) in
                // 输出边运行边读：等退出后再读，子进程写满管道缓冲就会阻塞，永远不退出。
                let collected = CollectedOutput()
                let group = DispatchGroup()
                group.enter()
                process.terminationHandler = { p in
                    collected.status = p.terminationStatus
                    group.leave()
                }
                do { try process.run() } catch {
                    c.resume(throwing: MacVMError.io(String(l10n: "Couldn't run \(executable): \(error.localizedDescription)")))
                    return
                }
                // 取消发生在 run 之前时 onCancel 看不到在运行的进程，这里补上。
                if Task.isCancelled { running.terminate() }
                if output == nil {
                    group.enter()
                    DispatchQueue.global().async {
                        collected.out = stdout.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                if !passthroughStderr {
                    group.enter()
                    DispatchQueue.global().async {
                        collected.err = stderr.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                group.notify(queue: .global()) { c.resume(returning: (collected.status, collected.out, collected.err)) }
            }
        } onCancel: {
            running.terminate()
        }
        // 取消时子进程被终止，非零退出码不是失败原因。
        try Task.checkCancellation()
        let (status, out, err) = result
        guard acceptedExitCodes.contains(status) else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacVMError.io(String(l10n: "\((executable as NSString).lastPathComponent) exited with code \(status)") + (message.isEmpty ? "" : String(l10n: ": \(message)")))
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// 每个字段只由一个线程写，`DispatchGroup.notify` 之后才读。
private final class CollectedOutput: @unchecked Sendable {
    var status: Int32 = 0
    var out = Data()
    var err = Data()
}

/// 本进程启动、还没结束的子进程。退出前要终止它们：子进程不会随父进程退出，留下的 curl 会接着往下载文件里写。
public enum ChildProcesses {
    private static let running = Mutex<[ObjectIdentifier: RunningProcess]>([:])

    static func register(_ process: RunningProcess) {
        running.withLock { $0[ObjectIdentifier(process)] = process }
    }

    static func unregister(_ process: RunningProcess) {
        running.withLock { $0[ObjectIdentifier(process)] = nil }
    }

    public static func terminateAll() {
        for process in running.withLock({ Array($0.values) }) { process.terminate() }
    }
}

/// 让任务取消时能从任意线程终止子进程。`Process.terminate` 可在任意线程调用，这里只用它和 `isRunning`。
final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
