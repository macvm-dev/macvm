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
