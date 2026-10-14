import Foundation
import Testing
import ACPKit

@testable import CodevisorClient
import CodevisorProtocol

@Suite("Server client body encoding")
struct CodevisorServerClientBodyTests {
  @Test("Snapshot sync sends its title as a fallback, never a rename")
  func sessionTitleIntent() throws {
    let session = ChatSession(projectId: UUID(), title: "First message")
    let fallback = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(UpdateSessionBody(session: session))
    )
    #expect(fallback["titleIntent"] == .string("fallback"))
    #expect(fallback["title"] == .string("First message"))
  }

  @Test("SetGoalBody encodes the token-budget double-option")
  func setGoalBodyEncoding() throws {
    func json(_ body: SetGoalBody) throws -> String {
      String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }
    let keep = try json(SetGoalBody(objective: "o", status: nil, tokenBudget: .keep, clientActionId: "a"))
    #expect(!keep.contains("tokenBudget"))
    let clear = try json(SetGoalBody(objective: nil, status: nil, tokenBudget: .clear, clientActionId: "a"))
    #expect(clear.contains(#""tokenBudget":null"#))
    #expect(!clear.contains("objective"))
    let set = try json(SetGoalBody(objective: nil, status: .paused, tokenBudget: .set(50_000), clientActionId: "a"))
    #expect(set.contains(#""tokenBudget":50000"#))
    #expect(set.contains(#""status":"paused""#))
  }
}
