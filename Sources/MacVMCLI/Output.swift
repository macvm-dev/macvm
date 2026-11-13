import ArgumentParser
import Foundation
import MacVMModel

struct Empty: Encodable, Sendable {}

enum Output {
    /// 执行命令主体：成功时按 `--json` 输出结果，失败时输出错误并以契约退出码结束。
    static func run<R: Encodable & Sendable>(
        json: Bool,
        isolation: isolated (any Actor)? = #isolation,
        human: (R) -> String?,
        _ body: () async throws -> R
    ) async throws {
        do {
            let result = try await body()
            if json {
                try printLine(JSONEnvelope.success(result).encoded())
            } else if let text = human(result), !text.isEmpty {
                print(text)
            }
        } catch let error as DetailedError {
            report(error.error, blockingApps: error.blockingApps, json: json)
            throw ExitCode(error.error.exitCode)
        } catch let error as MacVMError {
            report(error, json: json)
            throw ExitCode(error.exitCode)
        } catch let error as ExitCode {
            throw error
        } catch {
            let wrapped = MacVMError.engine(error.localizedDescription)
            report(wrapped, json: json)
            throw ExitCode(wrapped.exitCode)
        }
    }

    static func report(_ error: MacVMError, blockingApps: [GuestApp]? = nil, json: Bool) {
        if json, let data = try? JSONEnvelope<Empty>.failure(error, blockingApps: blockingApps).encoded() {
            printLine(data)
        } else {
            FileHandle.standardError.write(Data("macvm: \(error.message)\n".utf8))
        }
    }

    private static func printLine(_ data: Data) {
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}
