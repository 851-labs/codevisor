import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite
struct SessionControllerQueuedFlightTests {
  @Test("A queued message flies out of the queue only while its chat is on screen")
  func queuedFlightNeedsVisibleTranscript() {
    let fixture = Fixture()
    defer { fixture.model.shutdown() }
    var flights: [UUID] = []
    fixture.controller.onQueuedPromptWillFly = { flights.append($0) }
    let whileHidden = UUID()
    let whileShown = UUID()

    fixture.promote(whileHidden)
    #expect(flights.isEmpty)
    #expect(fixture.controller.userSendAnimationRequest?.messageID == whileHidden)

    fixture.controller.presentationClock.viewDidAppear()
    fixture.promote(whileShown)
    #expect(flights == [whileShown])
    #expect(fixture.controller.userSendAnimationRequest?.messageID == whileShown)
  }

  @MainActor
  private final class Fixture {
    let controller: SessionController
    let model: SessionModel

    init() {
      let sessionId = UUID()
      let client = FakeSessionServerClient(sessionId: sessionId)
      controller = SessionController(
        project: Project.fromFolder(URL(fileURLWithPath: "/fixture/project"), serverId: "local"),
        configCache: ConfigOptionCache(store: InMemoryStore()),
        serverClient: client)
      model = controller.makeServerSessionModel(
        transport: ServerSessionTransport(client: client, sessionId: sessionId),
        harnessId: "codex",
        sessionId: sessionId)
    }

    func promote(_ messageID: UUID) {
      let id = messageID.uuidString
      model.promptQueue.apply([
        ServerPromptQueueItem(
          id: id, sessionId: "session", text: id,
          createdAt: "2026-11-04T00:00:00.000Z", updatedAt: "2026-11-04T00:00:00.000Z")
      ])
      model.promptQueue.apply([])
      model.apply(.userMessage(id: id, text: id, attachments: []))
    }
  }
}
