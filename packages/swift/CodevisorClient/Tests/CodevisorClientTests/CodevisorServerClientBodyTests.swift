import Foundation
import Testing
import ACPKit

@testable import CodevisorClient
import CodevisorProtocol

@Suite("Server client body encoding")
struct CodevisorServerClientBodyTests {
  @Test("Snapshot sync and explicit renames carry distinct title intent")
  func sessionTitleIntent() throws {
    let session = ChatSession(projectId: UUID(), title: "First message")
    let fallback = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(UpdateSessionBody(session: session))
    )
    let rename = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(RenameSessionBody(title: session.title))
    )
    #expect(fallback["titleIntent"] == .string("fallback"))
    #expect(fallback["title"] == .string("First message"))
    #expect(rename["titleIntent"] == .string("rename"))
    #expect(rename["title"] == fallback["title"])
  }

  @Test("SetGoalBody encodes the token-budget double-option")
  func setGoalBodyEncoding() throws {
    func json(_ body: SetGoalBody) throws -> String {
      String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }
    // .keep omits the key entirely.
    let keep = try json(SetGoalBody(objective: "o", status: nil, tokenBudget: .keep, clientActionId: "a"))
    #expect(!keep.contains("tokenBudget"))
    // .clear encodes a literal null.
    let clear = try json(SetGoalBody(objective: nil, status: nil, tokenBudget: .clear, clientActionId: "a"))
    #expect(clear.contains(#""tokenBudget":null"#))
    #expect(!clear.contains("objective"))
    // .set encodes the number; status uses its raw wire string.
    let set = try json(SetGoalBody(objective: nil, status: .paused, tokenBudget: .set(50_000), clientActionId: "a"))
    #expect(set.contains(#""tokenBudget":50000"#))
    #expect(set.contains(#""status":"paused""#))
  }

  @Test("Event WebSockets accept bounded multi-megabyte tool results")
  func eventWebSocketLimit() {
    #expect(CodevisorServerClient.eventWebSocketMaximumMessageSize == 16 * 1024 * 1024)
  }
}
