import Foundation
import Testing
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  @Test("Repeated mark-read calls with nothing unseen send no extra requests")
  func repeatedMarkReadIsIdempotent() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/idempotent-read"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Focused"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    await fakeServer.setSessionAttention(
      id: session.id,
      latestSequence: 1,
      lastSeenSequence: 0
    )
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.unreadCount == 1
    }

    model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    try await waitUntilAsync {
      await fakeServer.snapshot().readRequests.count == 1
    }
    #expect(model.sessions.first(where: { $0.id == session.id })?.unreadCount == 0)

    // Focus-read fires continuously while a chat stays focused; repeated
    // triggers with nothing unseen must not spam the server.
    model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    model.markSessionRead(session.id, serverId: session.serverId)
    try await Task.sleep(for: .milliseconds(20))
    let readRequests = await fakeServer.snapshot().readRequests
    #expect(readRequests.map(\.throughSequence) == [1])
  }

  @Test("A presented terminal event reads the server tip before navigation catches up")
  func presentedTurnEndReadsAheadOfNavigation() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/presented-turn-read"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Presented"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 0
    }

    // The terminal event has already reached the visible transcript and
    // the server transaction has advanced attention, but the independent
    // navigation socket has not delivered that summary to this model yet.
    await fakeServer.setSessionAttention(
      id: session.id, latestSequence: 1, lastSeenSequence: 0
    )
    model.acknowledgePresentedTurnEnd(
      session.id,
      serverId: session.serverId,
      throughSequence: 1
    )

    try await waitUntilAsync { await fakeServer.snapshot().readRequests.count == 1 }
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.unreadCount == 0
    }
    let snapshot = await fakeServer.snapshot()
    #expect(snapshot.readRequests.map(\.throughSequence) == [1])
    #expect(
      model.sessions.first(where: { $0.id == session.id })?.lastSeenAttentionSequence == 1
    )
  }

  @Test("A presented terminal acknowledgement cannot consume a later turn")
  func presentedTurnEndPreservesLaterAttention() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/presented-turn-bound"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Bounded"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 0
    }

    // A second autonomous turn can finish before a delayed request reaches
    // the server. The presented boundary is still sequence 1, so sequence
    // 2 must remain unread.
    await fakeServer.setSessionAttention(
      id: session.id, latestSequence: 2, lastSeenSequence: 0
    )
    model.acknowledgePresentedTurnEnd(
      session.id,
      serverId: session.serverId,
      throughSequence: 1
    )

    try await waitUntilAsync { await fakeServer.snapshot().readRequests.count == 1 }
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 2
    }
    let current = model.sessions.first(where: { $0.id == session.id })
    #expect(current?.lastSeenAttentionSequence == 1)
    #expect(current?.unreadCount == 1)
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [1])
  }

  @Test("A delayed read response cannot overwrite newer unread attention")
  func delayedReadResponseDoesNotOverwriteNewerAttention() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/stale-read-response"))
    let session = ChatSession(
      id: UUID(), projectId: project.id, harnessId: "codex", title: "Race"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    await fakeServer.setSessionAttention(
      id: session.id, latestSequence: 1, lastSeenSequence: 0
    )
    let responseGate = Latch()
    await fakeServer.setReadResponseDelay { await responseGate.wait() }
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 1
    }

    model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    try await waitUntilAsync { await fakeServer.snapshot().readRequests.count == 1 }
    await fakeServer.setSessionAttention(
      id: session.id, latestSequence: 2, lastSeenSequence: 1
    )
    await model.refreshFromServer()
    await responseGate.open()
    try await Task.sleep(for: .milliseconds(20))

    let current = model.sessions.first(where: { $0.id == session.id })
    #expect(current?.latestAttentionSequence == 2)
    #expect(current?.lastSeenAttentionSequence == 1)
    #expect(current?.unreadCount == 1)
  }
}
