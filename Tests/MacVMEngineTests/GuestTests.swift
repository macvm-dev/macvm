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
