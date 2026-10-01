import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Opening a chat this device has seen shows its saved page while the open
/// request is in flight; the server's page then replaces it. The saved page
/// is read off the main actor, so it races the request, and the server's page
/// must win that race whatever the order.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionControllerTranscriptCacheTests {
  @Test("The saved page shows before the open returns, then the server's page replaces it")
  func savedPageShowsUntilServerPageArrives() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.client.openSessionGate = gate
    defer { release.finish() }

    let connect = Task { try await fixture.controller.connect(harnessId: "codex") }
    await awaitObserved { fixture.controller.model != nil }
    #expect(fixture.userTexts() == ["saved"])

    release.finish()
    let model = try await connect.value
    #expect(model === fixture.controller.model)
    #expect(fixture.userTexts() == ["fresh"])
  }

  @Test("A failed open still shows the saved page")
  func failedOpenShowsSavedPage() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    fixture.client.openSessionFailure = .invalidResponse

    await #expect(throws: CodevisorServerClientError.self) {
      try await fixture.controller.connect(harnessId: "codex")
    }

    #expect(fixture.userTexts() == ["saved"])
  }

  @Test("A saved page read after the server's page arrived is never shown")
  func lateSavedPageIsDropped() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let transport = ServerSessionTransport(client: fixture.client, sessionId: fixture.sessionId)
    let model = fixture.controller.makeServerSessionModel(
      transport: transport, harnessId: "codex", sessionId: fixture.sessionId)

    let load = try #require(
      fixture.controller.startCachedTranscriptLoad(
        in: model, transport: transport, sessionId: fixture.sessionId, serverId: "local",
        loadsExistingHistory: true))
    // What `connect` does the moment the open response is in hand. The read
    // has not even started: its task needs the main actor this test holds.
    fixture.controller.supersedeCachedTranscriptLoad()
    await load.value

    #expect(fixture.controller.model == nil)
    #expect(fixture.controller.cachedTranscriptModel == nil)
    #expect(model.conversation.isEmpty)
  }

  @MainActor
  private final class Fixture {
    let sessionId = UUID()
    let client: FakeSessionServerClient
    let controller: SessionController
    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)

    init() throws {
      let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/project"), serverId: "local")
      let cache = TranscriptPageCache(directory: cacheDirectory)
      let saved = Self.openResponse(sessionId: sessionId, project: project, text: "saved")
      cache.store(saved, machineId: "local", sessionId: sessionId)
      client = FakeSessionServerClient(sessionId: sessionId)
      client.openSessionResponse = try JSONDecoder().decode(
        ServerSessionOpenResponse.self, from: Self.openResponse(sessionId: sessionId, project: project, text: "fresh"))
      controller = SessionController(
        project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client)
      controller.transcriptCache = cache
      controller.configureExistingSession(
        ChatSession(
          id: sessionId, projectId: project.id, serverId: "local", harnessId: "codex", agentSessionId: "agent-1",
          title: "Seen before", createdAt: Date(timeIntervalSince1970: 1)))
    }

    func userTexts() -> [String] {
      (controller.model?.conversation ?? []).compactMap { item in
        guard case .user(let user) = item else { return nil }
        return user.text
      }
    }

    func tearDown() {
      controller.model?.shutdown()
      try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// An open response holding one user message, as the server sends it.
    static func openResponse(sessionId: UUID, project: Project, text: String) -> Data {
      Data(
        """
        {
          "session": {
            "id": "\(sessionId.uuidString)", "projectId": "\(project.id.uuidString)", "serverId": "local",
            "harnessId": "codex", "agentSessionId": "agent-1", "title": "Seen before", "origin": "codevisor",
            "createdAt": "2026-09-08T17:45:00Z"
          },
          "transcript": {
            "items": [
              {
                "id": "\(UUID().uuidString)", "sessionId": "\(sessionId.uuidString)", "sequence": 0,
                "role": "user", "text": "\(text)", "createdAt": "2026-09-08T17:45:00.000Z",
                "updatedAt": "2026-09-08T17:45:00.000Z", "isGenerating": false, "hasDetails": false,
                "revision": 1
              }
            ],
            "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 1
          }
        }
        """.utf8)
    }
  }
}
