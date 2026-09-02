import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

struct ServerSessionTests {
  @Test("Mapping preserves the client machine scope instead of the server's internal id")
  func preservesClientMachineScope() throws {
    let sessionId = UUID()
    let projectId = UUID()
    let remote = ServerSession(
      id: sessionId.uuidString,
      projectId: projectId.uuidString,
      serverId: "local",
      harnessId: "claude-code",
      agentSessionId: "agent-session",
      title: "Remote chat",
      origin: .codevisor,
      isArchived: false,
      createdAt: "2026-08-19T17:24:12.550Z"
    )

    let mapped = try remote.chatSession(serverId: "cloud:machine-123")

    #expect(mapped.id == sessionId)
    #expect(mapped.projectId == projectId)
    #expect(mapped.serverId == "cloud:machine-123")
  }
}
