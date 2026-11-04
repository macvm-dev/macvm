import Foundation
@testable import MacVMEngine
import MacVMModel
import Testing

struct AgentTokenTests {
    private struct Sample: Decodable { let token, challenge, auth: String }

    @Test func answersMatchFixtures() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../guest/agent-protocol/fixtures/auth.jsonl")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let s = try JSONDecoder().decode(Sample.self, from: Data(line.utf8))
            #expect(AgentToken.answer(token: s.token, challenge: s.challenge) == s.auth)
        }
    }

    @Test func randomTokensAreLongAndDistinct() {
        let a = AgentToken.random(), b = AgentToken.random()
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit) && a != b)
    }

    /// 宿主端与代理端各一个 `UnixSocket`。
    private func connected() throws -> (host: UnixSocket, agent: UnixSocket) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (UnixSocket(fd: fds[0]), UnixSocket(fd: fds[1]))
    }

    @Test func answersChallengeWithToken() throws {
        let (host, agent) = try connected()
        try agent.writeLine(Data(#"{"challenge":"abc"}"#.utf8))
        try AgentToken.authenticate(host, token: "secret", name: "vm")
        let line = try #require(try agent.readLine())
        let reply = try #require(try JSONSerialization.jsonObject(with: line) as? [String: String])
        #expect(reply == ["auth": AgentToken.answer(token: "secret", challenge: "abc")])
    }

    @Test func failsWithoutChallenge() throws {
        let (host, agent) = try connected()
        try agent.writeLine(Data(#"{"ok":true}"#.utf8))
        #expect(throws: (any Error).self) { try AgentToken.authenticate(host, token: "secret", name: "vm") }

        let (closedHost, closedAgent) = try connected()
        shutdown(closedAgent.fd, SHUT_RDWR)
        #expect(throws: (any Error).self) { try AgentToken.authenticate(closedHost, token: "secret", name: "vm") }
    }

    @Test func bundleWithoutTokenOnlyWorksWhenNotBridged() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-token-\(UUID().uuidString).macvm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let (host, _) = try connected()
        #expect(throws: (any Error).self) { try AgentToken.authenticate(host, bundle: bundle, bridged: true) }
        #expect(throws: Never.self) { try AgentToken.authenticate(host, bundle: bundle, bridged: false) }

        try AgentToken.store("secret", in: bundle)
        let (tokenHost, agent) = try connected()
        try agent.writeLine(Data(#"{"challenge":"xyz"}"#.utf8))
        try AgentToken.authenticate(tokenHost, bundle: bundle, bridged: true)
        let line = try #require(try agent.readLine())
        #expect(line == Data(#"{"auth":"\#(AgentToken.answer(token: "secret", challenge: "xyz"))"}"#.utf8))
    }
}
