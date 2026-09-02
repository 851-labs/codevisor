import Foundation
import Testing

@testable import CodevisorClient
import CodevisorProtocol

@Suite("Server client body encoding")
struct CodevisorServerClientBodyTests {
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
