import Foundation
@testable import MacVMEngine
import Testing

struct CursorShapeTests {
    @Test func decodesFixtures() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../protocol/fixtures/cursors.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let shapes = try lines.map { try JSONDecoder().decode(AgentProtocol.CursorShape.self, from: Data($0.utf8)) }
        #expect(shapes.count == 3)
        let image = try #require(Data(base64Encoded: shapes[0].bgra).flatMap { cursorImage(bgra: $0, width: shapes[0].width, height: shapes[0].height) })
        #expect(image.width == 2 && image.height == 1 && shapes[0].hot_x == 1)
        #expect(shapes[1].hidden && cursorImage(bgra: Data(), width: 0, height: 0) == nil)
        #expect(shapes[2].system == "ibeam" && !shapes[2].hidden)
    }
}

struct SSHConfigIncludeTests {
    @Test func removingIncludeUndoesInstall() {
        let existing = "Host work\n  HostName example.com\n"
        let installed = SSHConfig.includeLine + "\n\n" + existing
        #expect(SSHConfig.removingInclude(from: installed) == existing)
        #expect(SSHConfig.removingInclude(from: existing) == existing)
    }
}
