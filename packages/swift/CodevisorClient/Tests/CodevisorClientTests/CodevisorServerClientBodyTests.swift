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

  @Test("Creating a session's workspace asks for its draft's sidebar position")
  func draftSidebarPosition() throws {
    let session = ChatSession(projectId: UUID(), title: "First message")
    let draftId = UUID()
    let position = WorkspacePosition.initial(createdAt: Date(timeIntervalSince1970: 1), id: draftId)
    WorkspaceOrderClock.shared.observeDrafts([draftId: position])
    defer { WorkspaceOrderClock.shared.observeDrafts([:]) }
    func json(_ body: some Encodable) throws -> JSONValue {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(body))
    }
    #expect(try json(CreateSessionBody(session: session, workspaceId: draftId))["sidebarPosition"] == .string(position))
    #expect(try json(UpdateSessionBody(session: session, workspaceId: draftId))["sidebarPosition"] == .string(position))
    #expect(try json(CreateSessionBody(session: session, workspaceId: UUID()))["sidebarPosition"] == nil)
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
