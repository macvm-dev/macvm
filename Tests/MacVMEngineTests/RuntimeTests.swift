import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct ControlProtocolTests {
    @Test(arguments: [
        ControlRequest.status, .stop(force: true), .stop(force: false), .suspend, .pause, .resume,
        .connect(port: 6100), .screenshot(path: "/tmp/a.png"), .display(width: 2560, height: 1600),
    ])
    func roundTrip(request: ControlRequest) throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func stopDefaultsToGraceful() throws {
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"op":"stop"}"#.utf8)) == .stop(force: false))
    }

    @Test(arguments: [
        MacVMError.notRunning("vm"), .alreadyRunning("vm"), .io("写入失败"), .timeout("超时"), .invalidConfig("坏配置"), .engine("出错"),
    ])
    func failureKeepsErrorCode(error: MacVMError) {
        #expect(ControlResponse(failure: error).failure == error)
    }

    @Test func unknownFailureCodeIsEngine() {
        #expect(ControlResponse(ok: false, errorCode: "bad_request", message: "坏请求").failure == .engine("坏请求"))
        #expect(ControlResponse(ok: true).failure == nil)
    }
}

struct UnixSocketTests {
    @Test func exactReadLineLeavesFollowingBytesInDescriptor() throws {
        var ends: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let reader = UnixSocket(fd: ends[0]), writer = UnixSocket(fd: ends[1])
        try writer.writeAll(Data("{\"ok\":true}\nrest".utf8))
        #expect(try reader.readLine(exact: true) == Data("{\"ok\":true}".utf8))
        #expect(reader.takeBuffered().isEmpty)
        var rest = [UInt8](repeating: 0, count: 4)
        #expect(read(reader.fd, &rest, rest.count) == 4)
        #expect(rest == Array("rest".utf8))
    }

    @Test func acceptReturnsBlockingConnectionAndStopsWhenCancelled() throws {
        let path = "/tmp/macvm-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(at: path)
        defer { unlink(path) }
        var wake: [Int32] = [-1, -1]
        #expect(pipe(&wake) == 0)
        defer { for end in wake { close(end) } }
        let client = try UnixSocket.connect(to: path)
        let accepted = try #require(listener.accept(cancel: wake[0]))
        #expect(fcntl(accepted.fd, F_GETFL) & O_NONBLOCK == 0)
        var byte: UInt8 = 0
        #expect(write(wake[1], &byte, 1) == 1)
        #expect(listener.accept(cancel: wake[0]) == nil)
        withExtendedLifetime(client) {}
    }
}

struct AttachedImageTests {
    @Test func discImagesAttachReadOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.iso", "b.ISO", "c.dmg", "d.img"] {
            try Data().write(to: dir.appending(path: name))
        }
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "a.iso")))
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "b.ISO")))
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "c.dmg")))
        #expect(!AttachedImage.prefersReadOnly(dir.appending(path: "d.img")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.appending(path: "d.img").path)
        #expect(AttachedImage.prefersReadOnly(dir.appending(path: "d.img")))
    }
}

@MainActor
struct StopLatchTests {
    @Test(arguments: [(MachineStopReason.guestShutdown, true), (.forced, true), (.suspended, false), (.error("崩溃"), false)])
    func poweredOffMarkerFollowsStopReason(reason: MachineStopReason, marked: Bool) throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appending(path: "macvm-latch-\(UUID().uuidString).macvm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        FileManager.default.createFile(atPath: bundle.poweredOffMarkerURL.path, contents: nil)

        let latch = StopLatch(bundle: bundle, lock: try BundleLock.acquire(bundle))
        latch.started()
        #expect(!bundle.wasPoweredOff)
        latch.fire(reason)
        #expect(bundle.wasPoweredOff == marked)
    }
}
