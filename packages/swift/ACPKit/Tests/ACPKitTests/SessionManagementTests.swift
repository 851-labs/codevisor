import Foundation
import Testing
@testable import ACPKit

@Suite("Session management")
struct SessionManagementTests {
  @Test("SessionInfo decodes from agent JSON")
  func sessionInfoDecoding() throws {
    let json = #"{"sessionId":"a","cwd":"/x","title":"T"}"#
    let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
    #expect(info == SessionInfo(sessionId: "a", cwd: "/x", title: "T"))
  }
}
