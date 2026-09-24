import CodevisorProtocol
import Foundation
import Testing

@testable import CodevisorClient

/// The device saves the last navigation snapshot it received and reads it
/// back on the next launch, so every record in it must survive being written
/// and decoded again by the same decoder the client uses for the network.
struct ServerNavigationCodingTests {
  static let wire = """
    {"eventCursor":42,
     "projects":[{"id":"p1","name":"Codevisor","origin":"codevisor","createdAt":"2026-09-01T00:00:00Z",
       "locations":[{"id":"l1","projectId":"p1","serverId":"local","folderPath":"/src","createdAt":"2026-09-01T00:00:00Z","isGitRepository":true}],
       "worktreeBase":{"remote":"origin","branch":"main"},"isScratch":false}],
     "sessions":[{"id":"s1","projectId":"p1","serverId":"local","harnessId":"codex","title":"Fix it","origin":"codevisor",
       "workspaceId":"w1","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z",
       "usage":{"used":10,"size":100,"costAmount":0.5,"costCurrency":"USD"},
       "latestAttentionSequence":3,"lastSeenAttentionSequence":2,"unreadCount":1,"actionRequired":false}],
     "workspaces":[{"id":"w1","serverId":"local","projectId":"p1","name":"Sushi","hasCustomName":true,
       "rootDirectory":"/src/.worktrees/sushi","isArchived":true,"archivedAt":"2026-09-03T00:00:00Z",
       "createdAt":"2026-09-01T00:00:00Z","sidebarPosition":"a0","sidebarOrderRevision":4}],
     "panes":[{"id":"s1","workspaceId":"w1","providerId":"codevisor","paneType":"chat","title":"Fix it",
       "resourceKind":"session","resourceId":"s1","revision":2,"createdAt":"2026-09-01T00:00:00Z"}]}
    """

  @Test("A saved snapshot decodes back to the one the server sent")
  func snapshotRoundTrip() throws {
    let decoder = CodevisorServerClient().decoder
    let received = try decoder.decode(ServerNavigationSnapshot.self, from: Data(Self.wire.utf8))
    let saved = try JSONEncoder().encode(received)
    let restored = try decoder.decode(ServerNavigationSnapshot.self, from: saved)
    #expect(restored == received)
    #expect(restored.workspaces.first?.isArchived == true)
    #expect(restored.sessions.first?.usage?.costAmount == 0.5)
    #expect(restored.projects.first?.locations.first?.isGitRepository == true)
  }

  @Test("Opening a chat hands back the exact bytes it decoded")
  func openReturnsRawBody() async throws {
    let client = CodevisorServerClient(config: .init(requestTransport: OpenTransport()))
    let chat = ChatSession(id: OpenTransport.sessionId, projectId: OpenTransport.projectId, title: "Fix it")
    let result = try #require(
      try await client.openSessionReturningData(chat, project: nil, workspaceId: nil, transcriptLimit: 16))
    #expect(result.data == Data(OpenTransport.body.utf8))
    #expect(result.response.session.title == "Fix it")
    let reopened = try await client.openSession(chat, project: nil, workspaceId: nil, transcriptLimit: 16)
    #expect(reopened?.transcript.eventCursor == 9)
  }
}

private actor OpenTransport: ServerRequestTransport {
  static let sessionId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  static let projectId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  static let body = """
    {"session":{"id":"\(sessionId)","projectId":"\(projectId)","serverId":"local","harnessId":"codex",
      "title":"Fix it","origin":"codevisor","createdAt":"2026-09-01T00:00:00Z"},
     "transcript":{"items":[],"hasNewer":false,"hasMore":false,"eventCursor":9,"setupActivities":[],"stateUpdates":[]}}
    """

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (
      Data(Self.body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
