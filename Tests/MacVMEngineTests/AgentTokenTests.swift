import Foundation
@testable import MacVMEngine
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
}
