import Foundation
import Testing
@testable import CodevisorProtocol

@Suite("ChatSession")
struct ChatSessionTests {
  @Test("Nil and empty agent ids are both deferred")
  func deferredAgentIdentity() {
    var session = ChatSession(projectId: UUID())

    #expect(!session.hasAgentSession)

    session.agentSessionId = ""
    #expect(!session.hasAgentSession)

    session.agentSessionId = "agent-1"
    #expect(session.hasAgentSession)
  }
}
