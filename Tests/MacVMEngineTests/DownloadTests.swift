import Foundation
@testable import MacVMEngine
import Testing

struct DownloadTests {
    private func expectContiguous(_ ranges: [ClosedRange<Int64>], length: Int64) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == length - 1)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(b.lowerBound == a.upperBound + 1) }
    }

    @Test func chunksCoverRange() {
        let parts = Download.chunks(0...999, size: 300)
        #expect(parts == [0...299, 300...599, 600...899, 900...999])
        #expect(Download.chunks(5...5, size: 300) == [5...5])
    }

    @Test func plannedRangesKeepExistingPrefixAsFirstChunk() {
        let ranges = Download.plannedRanges(length: 1000, prefix: 600, chunk: 100)
        #expect(ranges.first == 0...599)
        #expect(ranges.count == 5)
        expectContiguous(ranges, length: 1000)
        expectContiguous(Download.plannedRanges(length: 1000, prefix: 0, chunk: 100), length: 1000)
    }

    @Test func refineSplitsLargeUnfinishedRanges() {
        let refined = Download.refine([0...999, 1000...1099], chunk: 100) { $0.lowerBound == 0 ? 150 : 0 }
        #expect(refined.first == 0...249)
        #expect(refined.contains(1000...1099))
        expectContiguous(refined, length: 1100)
        #expect(Download.refine([0...999], chunk: 100) { _ in 900 } == [0...999])
    }

    @Test func probeReadsFinalResponseAfterRedirects() throws {
        let output = """
        HTTP/1.1 302 Found\r
        Location: https://mirror.example/f.iso\r
        Content-Length: 0\r
        \r
        HTTP/2 200\r
        content-length: 4154798080\r
        accept-ranges: bytes\r
        \r
        https://mirror.example/f.iso
        """
        let probe = try #require(Download.parseProbe(output))
        #expect(probe.url.absoluteString == "https://mirror.example/f.iso")
        #expect(probe.length == 4154798080)
    }

    @Test func probeWithoutLength() throws {
        let probe = try #require(Download.parseProbe("HTTP/1.1 200 OK\r\nContent-Type: x\r\n\r\nhttps://e.example/a"))
        #expect(probe.length == nil)
    }

    @Test func probeRejectsErrorStatus() {
        #expect(Download.parseProbe("HTTP/1.1 302 Found\r\n\r\nHTTP/2 404\r\ncontent-length: 9\r\n\r\nhttps://e.example/a") == nil)
    }
}

struct DownloadLockTests {
    @Test func secondHolderIsRefusedUntilRelease() throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "macvm-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target.appendingPathExtension("lock")) }
        let first = try #require(try DownloadLock(trying: target))
        #expect(try DownloadLock(trying: target) == nil)
        first.release()
        try #require(try DownloadLock(trying: target)).release()
    }

    @Test func acquireWaitsForRelease() async throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "macvm-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target.appendingPathExtension("lock")) }
        let first = try #require(try DownloadLock(trying: target))
        let waiter = Task { try await DownloadLock.acquire(target) }
        try await Task.sleep(for: .milliseconds(700))
        first.release()
        try await waiter.value.release()
    }

    @Test func verifySHA256KeepsMatchingFileAndDeletesMismatch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "macvm-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello".utf8).write(to: file)
        try await Download.verifySHA256(of: file, expected: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824", name: "f")
        #expect(FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: (any Error).self) { try await Download.verifySHA256(of: file, expected: "00", name: "f") }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removeStaleVirtioWinKeepsCurrentAndPartials() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macvm-virtio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["virtio-win-0.1.285.iso", "virtio-win-0.1.302.iso", "virtio-win-0.1.302.iso.part", "virtio-win-0.1.302.iso.part.lock"]
        for name in names { FileManager.default.createFile(atPath: root.appending(path: name).path, contents: nil) }
        WindowsInstaller.removeStaleVirtioWin(keeping: "virtio-win-0.1.302.iso", in: root)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["virtio-win-0.1.302.iso", "virtio-win-0.1.302.iso.part", "virtio-win-0.1.302.iso.part.lock"])
    }
}
