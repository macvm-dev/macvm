import Foundation
import MacVMModel

enum Subprocess {
    /// 运行外部命令并等待结束，非零退出时把 stderr 带进错误信息。
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], passthroughStderr: Bool = false, stdin: URL? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = passthroughStderr ? FileHandle.standardError : stderr
        process.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        let output = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Int32, Data, Data), any Error>) in
            process.terminationHandler = { p in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = passthroughStderr ? Data() : stderr.fileHandleForReading.readDataToEndOfFile()
                c.resume(returning: (p.terminationStatus, out, err))
            }
            do { try process.run() } catch {
                c.resume(throwing: MacVMError.io("无法运行 \(executable)：\(error.localizedDescription)"))
            }
        }
        let (status, out, err) = output
        guard status == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacVMError.io("\((executable as NSString).lastPathComponent) 退出码 \(status)\(message.isEmpty ? "" : "：" + message)")
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 用 curl 下载到 `destination`，已有部分内容时续传；`showProgress` 时进度条写到 stderr。
    static func download(_ url: URL, to destination: URL, showProgress: Bool) async throws {
        try await run("/usr/bin/curl", ["-fL", "--retry", "3", "-C", "-", showProgress ? "--progress-bar" : "-sS", "-o", destination.path, url.absoluteString],
                      passthroughStderr: showProgress)
    }
}
