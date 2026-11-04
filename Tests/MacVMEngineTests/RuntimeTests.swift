import Foundation
@testable import MacVMEngine
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
