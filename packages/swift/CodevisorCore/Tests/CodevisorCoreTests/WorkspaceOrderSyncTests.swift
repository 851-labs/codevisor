import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Sidebar moves go through the outbox as `reorderWorkspace` requests. The
/// move shows immediately and the latest move wins on the server, so a
/// workspace stays where the user put it.
@MainActor
struct WorkspaceOrderSyncTests {
  private func makeFixture(
    persistence: InMemoryStore = InMemoryStore(), revision: Int = 1
  ) async -> WorkspaceSyncFixture {
    await WorkspaceSyncFixture(persistence: persistence) { workspace, other in
      workspace.sidebarOrderRevision = revision
      other.sidebarOrderRevision = revision
    }
  }

  /// `otherWorkspace` is newer, so it starts above `workspace`.
  private func moveToTop(_ fixture: WorkspaceSyncFixture) {
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.workspace.id, fixture.otherWorkspace.id])
  }

  private func isOnTop(_ fixture: WorkspaceSyncFixture) throws -> Bool {
    let moved = try #require(fixture.current)
    let other = try #require(fixture.repository.workspace(id: fixture.otherWorkspace.id))
    return WorkspaceSidebarOrder.precedes(moved, other)
  }

  @Test("A move shows immediately and an older snapshot cannot undo it")
  func optimisticMoveSurvivesStaleSnapshot() async throws {
    let fixture = await makeFixture()
    #expect(try !isOnTop(fixture))
    let stale = fixture.server.current
    moveToTop(fixture)
    #expect(try isOnTop(fixture))

    await fixture.store.replace(
      stale, machineId: fixture.serverId, requestedAt: Date(timeIntervalSinceNow: -60), resetsStream: false)
    #expect(try isOnTop(fixture))

    fixture.connect()
    await fixture.settle()
    let record = try fixture.serverRecord(fixture.workspace.id)
    #expect(fixture.server.requests == ["reorder:1"])
    #expect(record.sidebarOrderRevision == 2)
    #expect(fixture.current?.sidebarPosition == record.sidebarPosition)
    #expect(fixture.current?.sidebarOrderRevision == 2)
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(try isOnTop(fixture))
  }

  @Test("Rapid drags coalesce into one request carrying the latest position")
  func rapidDragsCoalesce() async throws {
    let fixture = await makeFixture()
    moveToTop(fixture)
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id])
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.workspace.id, fixture.otherWorkspace.id])
    let latest = try #require(fixture.current?.sidebarPosition)
    #expect(fixture.store.pendingIntents.count == 1)

    fixture.connect()
    await fixture.settle()
    #expect(fixture.server.requests == ["reorder:1"])
    #expect(try fixture.serverRecord(fixture.workspace.id).sidebarPosition == latest)
    #expect(fixture.current?.sidebarPosition == latest)
  }

  @Test("A move queued while an earlier move is in flight still lands, and stays")
  func moveQueuedBehindInFlightMoveLands() async throws {
    let fixture = await makeFixture()
    fixture.connect()
    let started = TestSignal()
    let release = TestSignal()
    fixture.server.onRequest { name in
      guard name == "reorder:1", started.value == 0 else { return }
      started.signal()
      await release.wait()
    }
    moveToTop(fixture)
    await started.wait()
    // The cache hasn't seen the first move land, so this one is queued with
    // the same revision the first carried.
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id])
    let latest = try #require(fixture.current?.sidebarPosition)
    #expect(try !isOnTop(fixture))
    release.signal()
    await fixture.settle()
    #expect(fixture.server.requests == ["reorder:1", "reorder:1"])
    #expect(try fixture.serverRecord(fixture.workspace.id).sidebarPosition == latest)
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.sidebarPosition == latest)
    #expect(try !isOnTop(fixture))
  }

  @Test("A move made offline is applied when the device reconnects")
  func offlineMoveAppliesOnReconnect() async throws {
    let fixture = await makeFixture()
    moveToTop(fixture)
    let pending = try #require(fixture.current?.sidebarPosition)
    // Another device moved the same workspace while this one was offline.
    var earlier = try fixture.serverRecord(fixture.workspace.id)
    earlier.sidebarPosition = WorkspacePosition.initial(
      createdAt: Date(timeIntervalSince1970: 1_600_000_000), id: fixture.workspace.id)
    earlier.sidebarOrderRevision = 2
    fixture.server.commit(workspaces: [earlier])
    await fixture.deliver()
    #expect(try isOnTop(fixture))

    fixture.connect()
    await fixture.settle()
    #expect(fixture.server.requests == ["reorder:1"])
    #expect(try fixture.serverRecord(fixture.workspace.id).sidebarPosition == pending)
    #expect(fixture.current?.sidebarPosition == pending)
    #expect(fixture.current?.sidebarOrderRevision == 3)
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("Layout saves never change a workspace's order")
  func layoutSavesCannotOverwriteOrder() async throws {
    let fixture = await makeFixture()
    let oldLayout = try #require(fixture.current)
    moveToTop(fixture)
    let pending = try #require(fixture.current?.sidebarPosition)
    fixture.repository.save(oldLayout)
    #expect(fixture.current?.sidebarPosition == pending)

    fixture.connect()
    await fixture.settle()
    var stale = oldLayout
    stale.sidebarOrderRevision = 7
    fixture.repository.save(stale)
    fixture.store.rebuild()
    #expect(fixture.current?.sidebarPosition == pending)
    #expect(fixture.current?.sidebarOrderRevision == 2)
  }

  @Test("A pending move survives a relaunch and is sent afterwards")
  func pendingMovePersists() async throws {
    let persistence = InMemoryStore()
    let first = await makeFixture(persistence: persistence)
    moveToTop(first)
    let pending = try #require(first.current?.sidebarPosition)
    PersistenceEncoding.drain()

    let relaunched = NavigationFixture(persistence: persistence)
    #expect(relaunched.store.pendingIntents.map(\.intent.coalescingKey) == ["ws:\(first.workspace.id):order"])
    #expect(relaunched.workspaces.workspace(id: first.workspace.id)?.sidebarPosition == pending)

    let server = first.server
    relaunched.store.executor.clientProvider = { _ in server }
    relaunched.store.executor.isMachineReady = { _ in true }
    relaunched.store.executor.resume(machineId: first.serverId)
    await relaunched.store.executor.idle(machineId: first.serverId)
    await server.deliver(to: relaunched.store, machineId: first.serverId)
    #expect(server.requests == ["reorder:1"])
    #expect(relaunched.store.pendingIntents.isEmpty)
    #expect(relaunched.workspaces.workspace(id: first.workspace.id)?.sidebarPosition == pending)
    #expect(relaunched.workspaces.workspace(id: first.workspace.id)?.sidebarOrderRevision == 2)
  }

  @Test("A workspace the server never reordered expects revision 1")
  func unrevisionedWorkspaceExpectsFirstRevision() async throws {
    let fixture = await makeFixture(revision: 0)
    moveToTop(fixture)
    let intent = try #require(fixture.store.pendingIntents.first?.intent)
    guard case let .reorderWorkspace(_, _, expectedRevision) = intent else {
      Issue.record("Expected a reorder request, got \(intent)")
      return
    }
    #expect(expectedRevision == 1)
  }

  @Test("Moving a draft sends nothing: the server doesn't have it yet")
  func draftMoveSendsNothing() async throws {
    let fixture = await makeFixture()
    let draft = fixture.repository.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: UUID(), initialName: "Draft", serverId: fixture.serverId, projectId: fixture.project.id,
        rootDirectory: nil),
      legacyGroups: nil)
    fixture.sync.reorderWorkspace(id: draft.id, visibleIDs: [fixture.otherWorkspace.id, draft.id])
    #expect(fixture.store.pendingIntents.isEmpty)
  }
}
