import Foundation
import Testing
@testable import ACPKit

@Suite("Session management")
struct SessionManagementTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == value)
    }

    @Test("SessionInfo round-trips and derives its identity")
    func sessionInfoRoundTrip() throws {
        try roundTrip(SessionInfo(sessionId: "s", cwd: "/tmp", title: "Hi", updatedAt: "2026-06-30T06:32:48.000Z"))
        let info = SessionInfo(sessionId: "abc", cwd: "/tmp")
        #expect(info.id == "abc")
        #expect(info.title == nil)
    }

    @Test("SessionInfo decodes from agent JSON")
    func sessionInfoDecoding() throws {
        let json = #"{"sessionId":"a","cwd":"/x","title":"T"}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(info == SessionInfo(sessionId: "a", cwd: "/x", title: "T"))
    }
}
