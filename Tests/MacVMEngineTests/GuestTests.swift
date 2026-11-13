import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct CursorShapeTests {
    @Test func decodesFixtures() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../guest/agent-protocol/fixtures/cursors.jsonl")
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

    @Test func renderSkipsNamesThatCouldInjectDirectives() {
        func config(_ name: String, user: String?) -> VMConfig {
            VMConfig(name: name, os: .linux, cpuCount: 1, memorySize: 1 << 30, disks: [], guestUser: user)
        }
        let text = SSHConfig.render([
            config("good", user: "dev"),
            config("bad\nHost *\n  ProxyCommand evil", user: "dev"),
            config("bad-user", user: "x\nHost *\n  ProxyCommand evil"),
            config("dash-user", user: "-oProxyCommand=evil"),
        ], macvmPath: "/usr/local/bin/macvm")
        #expect(text.contains("Host good\n  User dev\n"))
        #expect(!text.contains("evil") && !text.contains("Host bad") && !text.contains("Host dash-user"))
        #expect(throws: (any Error).self) { try SSHConfig.validateLogin(user: "-oProxyCommand=evil", host: "good") }
        #expect(throws: Never.self) { try SSHConfig.validateLogin(user: "dev", host: "good") }
    }
}

struct GuestConnectionPumpTests {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    @Test func forwardsBothWaysAndReturnsWhenGuestCloses() throws {
        let (client, clientPeer) = pair()
        let (guest, guestPeer) = pair()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            GuestConnection.pump((client, client), guest)
            done.signal()
        }
        let host = UnixSocket(fd: clientPeer), vm = UnixSocket(fd: guestPeer)
        try host.writeLine(Data("hi".utf8))
        #expect(try vm.readLine() == Data("hi".utf8))
        try vm.writeLine(Data("yo".utf8))
        #expect(try host.readLine() == Data("yo".utf8))
        shutdown(guestPeer, SHUT_RDWR)
        #expect(done.wait(timeout: .now() + 5) == .success)
        close(client)
        close(guest)
    }
}

struct GuestFileTransferTests {
    @Test func conflictingNamesAreNumbered() {
        let taken: Set = ["a.txt", "a 2.txt", "dir.d", ".profile"]
        let name = { (n: String, dir: Bool) in GuestFileTransfer.uniqueName(n, isDirectory: dir) { taken.contains($0) } }
        #expect(name("b.txt", false) == "b.txt")
        #expect(name("a.txt", false) == "a 3.txt")
        #expect(name("dir.d", true) == "dir.d 2")
        #expect(name(".profile", false) == ".profile 2")
    }

    @Test func entryPathsCannotEscape() {
        #expect(AgentProtocol.FileEntry.split("a/b c/d") == ["a", "b c", "d"])
        for bad in ["", "/a", "a/", "a//b", "../a", "a/./b", "a\\b"] {
            #expect(AgentProtocol.FileEntry.split(bad) == nil, "\(bad)")
        }
    }

    @Test func guestPathNames() {
        #expect(GuestFileDrag.name(of: #"C:\Users\me\报告.docx"#) == "报告.docx")
        #expect(GuestFileDrag.name(of: "/Users/me/src") == "src")
    }
}

struct AgentRequestTests {
    @Test func requestFixturesRoundTrip() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../guest/agent-protocol/fixtures/requests.jsonl")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let request = try JSONDecoder().decode(AgentProtocol.Request.self, from: Data(line.utf8))
            let encoded = try JSONEncoder().encode(request)
            let expected = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
            let actual = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            #expect(actual == expected, "\(line)")
        }
    }

    @Test func responseFixturesDecode() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../guest/agent-protocol/fixtures/responses.jsonl")
        let responses = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(AgentProtocol.Response.self, from: Data($0.utf8))
        }
        #expect(responses.contains { $0.size == 48213 })
        #expect(responses.contains { $0.info?.features == [AgentProtocol.featureUI] })
        #expect(responses.contains { $0.info?.exeSHA256?.count == 64 })
        #expect(responses.contains { $0.files == [.init(path: "/Users/ethan/a.txt", dir: false), .init(path: "/Users/ethan/src", dir: true)] })
        #expect(responses.contains { $0.total == 1_048_576 })
        #expect(responses.contains { $0.serial == 42 })
        let pending = try #require(responses.first { $0.shutdown?.state == AgentProtocol.ShutdownStatus.statePending })
        #expect(pending.shutdown?.sinceMs == 95000)
        #expect(pending.shutdown?.apps?.first?.name == "Hermes")
        #expect(pending.shutdown?.apps?.last?.frontmost == true)
        #expect(responses.contains { $0.shutdown == .init(state: AgentProtocol.ShutdownStatus.stateNone, sinceMs: nil, apps: nil, error: nil) })
        let denied = try #require(responses.first { $0.code == "permission" })
        #expect(throws: MacVMError.permissionDenied(denied.error ?? "")) { try denied.checked() }
        let restarting = try #require(responses.first { $0.code == "restarting" })
        #expect(throws: AgentProtocol.Restarting.self) { try restarting.checked() }
    }

    @Test func uiSnapshotFixturesDecode() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../guest/agent-protocol/fixtures/ui.jsonl")
        let snapshots = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(AgentProtocol.UISnapshot.self, from: Data($0.utf8))
        }
        let full = try #require(snapshots.first)
        #expect(full.truncated && full.screen.scale == 2 && full.app?.frontmost == true)
        #expect(full.nodes.map(\.depth) == [0, 1, 2, 2, 2])
        #expect(full.nodes[4].states == ["checked", "disabled"] && full.nodes[3].actions == ["focus", "set-value"])
        #expect(snapshots.last?.app == nil && snapshots.last?.truncated == false)
    }

    /// 宿主端与代理端各一个 `UnixSocket`。
    private func connected() throws -> (host: UnixSocket, agent: UnixSocket) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (UnixSocket(fd: fds[0]), UnixSocket(fd: fds[1]))
    }

    @Test func bodyFollowsResponseLine() throws {
        let (host, agent) = try connected()
        // 响应行与正文一次写出，宿主读响应行时会把正文开头一并读进缓冲。
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0A])
        try agent.writeAll(Data(#"{"ok":true,"size":5}"#.utf8) + [0x0A] + png)
        let response = try #require(try host.readLine()).decoded()
        #expect(try AgentClient.body(after: response, from: host) == png)
    }

    @Test func bodyRejectsOversizeAndTruncation() throws {
        let (host, agent) = try connected()
        let oversize = try Data(#"{"ok":true,"size":\#(AgentProtocol.maxBody + 1)}"#.utf8).decoded()
        #expect(throws: MacVMError.self) { try AgentClient.body(after: oversize, from: host) }
        try agent.writeAll(Data("abc".utf8))
        shutdown(agent.fd, SHUT_WR)
        let short = try Data(#"{"ok":true,"size":10}"#.utf8).decoded()
        #expect(throws: MacVMError.self) { try AgentClient.body(after: short, from: host) }
    }

    @Test func inputEventsOmitDefaults() throws {
        let click = AgentProtocol.InputEvent.click(x: 1, y: 2, element: nil, button: .left, count: 1)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(click)) as? NSDictionary
        #expect(object == ["type": "click", "x": 1, "y": 2])
    }
}

private extension Data {
    func decoded() throws -> AgentProtocol.Response { try JSONDecoder().decode(AgentProtocol.Response.self, from: self) }
}
