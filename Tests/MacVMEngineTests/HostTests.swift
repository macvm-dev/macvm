import Foundation
@testable import MacVMEngine
import Testing

struct SubprocessCancellationTests {
    @Test func cancellingTerminatesChildProcess() async throws {
        let started = Date()
        let task = Task { try await Subprocess.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

struct SubprocessOutputTests {
    @Test func outputLargerThanPipeBufferDoesNotHang() async throws {
        let output = try await Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero >&2"])
        #expect(output.utf8.count == 300000)
    }
}
