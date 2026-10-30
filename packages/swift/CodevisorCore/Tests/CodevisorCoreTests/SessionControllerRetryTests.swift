import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionControllerRetryTests {
  @Test("An error without a stop kind after an event-only turn still offers a Retry that resends the event")
  func errorWithoutStopKindRetriesTheEvent() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    _ = try await fixture.controller.connect(harnessId: "claude-code")

    fixture.client.emit(
      ServerEventEnvelope(
        id: 2,
        serverId: "local",
        kind: "session.error",
        subjectId: fixture.sessionId.uuidString,
        createdAt: "2026-10-30T17:03:34.000Z",
        payload: .object(["message": .string("Claude Code stopped unexpectedly.")])
      ))
    await awaitObserved { fixture.controller.model?.errorMessage != nil }
    let failed = try #require(fixture.lastAssistantId())

    #expect(fixture.controller.canRetryTurn(failed))

    await fixture.controller.retryTurn(failed)
    #expect(fixture.client.promptedMessageIds == [fixture.eventId.uuidString.lowercased()])
  }

  @MainActor
  private final class Fixture {
    let sessionId = UUID()
    let eventId = UUID()
    let client: FakeSessionServerClient
    let controller: SessionController

    init() throws {
      let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/bot"), serverId: "local")
      client = FakeSessionServerClient(sessionId: sessionId)
      client.openSessionResponse = try JSONDecoder().decode(
        ServerSessionOpenResponse.self,
        from: Self.openResponse(sessionId: sessionId, eventId: eventId, project: project))
      controller = SessionController(
        project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client)
      controller.configureExistingSession(
        ChatSession(
          id: sessionId, projectId: project.id, serverId: "local", harnessId: "claude-code", agentSessionId: "agent-1",
          title: "My Bot", createdAt: Date(timeIntervalSince1970: 1)))
    }

    func lastAssistantId() -> UUID? {
      controller.conversation.last { item in
        if case .assistant = item { return true }
        return false
      }?.id
    }

    func tearDown() {
      controller.model?.shutdown()
    }

    static func openResponse(sessionId: UUID, eventId: UUID, project: Project) -> Data {
      Data(
        """
        {
          "session": {
            "id": "\(sessionId.uuidString)", "projectId": "\(project.id.uuidString)", "serverId": "local",
            "harnessId": "claude-code", "agentSessionId": "agent-1", "title": "My Bot", "origin": "codevisor",
            "createdAt": "2026-10-30T16:41:00Z"
          },
          "transcript": {
            "items": [
              {
                "id": "\(UUID().uuidString)", "sessionId": "\(sessionId.uuidString)", "sequence": 0,
                "role": "user", "messageId": "\(eventId.uuidString.lowercased())", "origin": "event",
                "text": "<codevisor-event type=\\"session.errored\\">Sub-agent stopped</codevisor-event>",
                "createdAt": "2026-10-30T16:41:00.000Z", "updatedAt": "2026-10-30T16:41:00.000Z",
                "isGenerating": false, "hasDetails": false, "revision": 1
              },
              {
                "id": "\(UUID().uuidString)", "sessionId": "\(sessionId.uuidString)", "sequence": 1,
                "role": "assistant", "text": "On it.", "stopReason": "end_turn",
                "createdAt": "2026-10-30T16:41:01.000Z", "updatedAt": "2026-10-30T16:41:05.000Z",
                "isGenerating": false, "hasDetails": false, "revision": 1
              }
            ],
            "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 1
          }
        }
        """.utf8)
    }
  }
}
