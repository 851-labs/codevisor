import Foundation
import Testing
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  private func attentionFixture(
    _ path: String, latest: Int = 0, lastSeen: Int = 0
  ) async -> (NavigationFixture, FakeServerClient, ChatSession) {
    let project = Project.fromFolder(URL(fileURLWithPath: path))
    let session = ChatSession(id: UUID(), projectId: project.id, harnessId: "codex", title: "Chat")
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    await fakeServer.setSessionAttention(id: session.id, latestSequence: latest, lastSeenSequence: lastSeen)
    let fixture = await NavigationFixture.connected(to: fakeServer)
    return (fixture, fakeServer, session)
  }

  @Test("Repeated mark-read calls with nothing unseen send no extra requests")
  func repeatedMarkReadIsIdempotent() async throws {
    let (fixture, fakeServer, session) = await attentionFixture("/tmp/idempotent-read", latest: 1)
    let model = fixture.projectList
    #expect(fixture.session(session.id)?.unreadCount == 1)

    model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    // Shown read at once, before the server has it.
    #expect(fixture.session(session.id)?.unreadCount == 0)
    await fixture.sync(with: fakeServer)
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [1])
    #expect(fixture.session(session.id)?.unreadCount == 0)

    // Focus-read fires continuously while a chat stays focused; repeated
    // triggers with nothing unseen must not spam the server.
    model.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    model.markSessionRead(session.id, serverId: session.serverId)
    #expect(fixture.store.pendingIntents.isEmpty)
    await fixture.flush()
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [1])
  }

  @Test("A presented terminal event reads the server tip before navigation catches up")
  func presentedTurnEndReadsAheadOfNavigation() async throws {
    let (fixture, fakeServer, session) = await attentionFixture("/tmp/presented-turn-read")
    #expect(fixture.session(session.id)?.latestAttentionSequence == 0)

    // The terminal event has already reached the visible transcript and
    // the server transaction has advanced attention, but the independent
    // navigation socket has not delivered that summary to this model yet.
    await fakeServer.setSessionAttention(id: session.id, latestSequence: 1, lastSeenSequence: 0)
    fixture.projectList.acknowledgePresentedTurnEnd(
      session.id,
      serverId: session.serverId,
      throughSequence: 1
    )

    await fixture.sync(with: fakeServer)
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [1])
    let current = try #require(fixture.session(session.id))
    #expect(current.unreadCount == 0)
    #expect(current.lastSeenAttentionSequence == 1)
  }

  @Test("A presented terminal acknowledgement cannot consume a later turn")
  func presentedTurnEndPreservesLaterAttention() async throws {
    let (fixture, fakeServer, session) = await attentionFixture("/tmp/presented-turn-bound")

    // A second autonomous turn can finish before a delayed request reaches
    // the server. The presented boundary is still sequence 1, so sequence
    // 2 must remain unread.
    await fakeServer.setSessionAttention(id: session.id, latestSequence: 2, lastSeenSequence: 0)
    fixture.projectList.acknowledgePresentedTurnEnd(
      session.id,
      serverId: session.serverId,
      throughSequence: 1
    )

    await fixture.sync(with: fakeServer)
    let current = try #require(fixture.session(session.id))
    #expect(current.latestAttentionSequence == 2)
    #expect(current.lastSeenAttentionSequence == 1)
    #expect(current.unreadCount == 1)
    #expect(await fakeServer.snapshot().readRequests.map(\.throughSequence) == [1])
  }

  @Test("A delayed read response cannot overwrite newer unread attention")
  func delayedReadResponseDoesNotOverwriteNewerAttention() async throws {
    let (fixture, fakeServer, session) = await attentionFixture("/tmp/stale-read-response", latest: 1)
    let responseGate = Latch()
    await fakeServer.setReadResponseDelay { await responseGate.wait() }
    #expect(fixture.session(session.id)?.latestAttentionSequence == 1)

    fixture.projectList.markSessionRead(session.id, serverId: session.serverId, throughSequence: 1)
    await fakeServer.waitForSnapshot { snapshot in snapshot.readRequests.count == 1 }
    // A newer turn finishes while the read's response is still in flight.
    await fakeServer.setSessionAttention(id: session.id, latestSequence: 2, lastSeenSequence: 1)
    await fixture.refresh(from: fakeServer)
    await responseGate.open()
    await fixture.flush()

    let current = try #require(fixture.session(session.id))
    #expect(current.latestAttentionSequence == 2)
    #expect(current.lastSeenAttentionSequence == 1)
    #expect(current.unreadCount == 1)
  }
}
