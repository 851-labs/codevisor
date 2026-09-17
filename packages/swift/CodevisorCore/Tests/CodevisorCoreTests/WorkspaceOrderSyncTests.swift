import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct WorkspaceOrderSyncTests {
  private func prepare(_ fixture: WorkspaceEventFixture) -> ServerWorkspace {
    var workspace = fixture.workspace
    workspace.sidebarPosition = WorkspacePosition.initial(createdAt: workspace.createdAt, id: workspace.id)
    workspace.sidebarOrderRevision = 1
    fixture.repository.saveWithSidebarOrder(workspace)
    var record = WorkspaceSyncModel.serverWorkspace(from: workspace)
    record.sidebarPosition = workspace.sidebarPosition
    record.sidebarOrderRevision = 1
    fixture.fake.setWorkspaces([record])
    return record
  }

  @Test func optimisticMoveSurvivesAStaleSnapshotAndCoalescesRapidDrags() async throws {
    let fixture = WorkspaceEventFixture()
    let original = prepare(fixture)
    let started = TestSignal()
    let release = TestSignal()
    let server = OrderServer(record: original)
    fixture.fake.workspaceOrderHandler = { _, position, revision in
      let attempt = await server.count()
      if attempt == 0 {
        started.signal()
        await release.wait()
      }
      return await server.move(position, revision: revision)
    }
    let task = fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id], client: fixture.fake
    )
    await started.wait()
    let optimistic = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(optimistic.pendingSidebarPosition != nil)
    #expect(optimistic.effectiveSidebarPosition > fixture.otherWorkspace.effectiveSidebarPosition)

    fixture.sync.reconcile(
      [original], paneRecords: [], protectedLocalPaneIds: [], assignments: [:], serverId: fixture.serverId)
    #expect(
      fixture.repository.workspace(id: fixture.workspace.id)?.effectiveSidebarPosition
        == optimistic.effectiveSidebarPosition)

    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.workspace.id, fixture.otherWorkspace.id], client: fixture.fake
    )
    let latest = try #require(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarPosition)
    release.signal()
    await task?.value
    let final = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(final.pendingSidebarPosition == nil)
    #expect(final.sidebarPosition == latest)
    #expect(final.sidebarOrderRevision == 3)
    #expect(await server.revisions() == [1, 2])
  }

  @Test func staleOfflineDragYieldsToTheServerWinner() async throws {
    let fixture = WorkspaceEventFixture()
    var winner = prepare(fixture)
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id], client: nil
    )
    winner.sidebarPosition = WorkspacePosition.initial(
      createdAt: Date(timeIntervalSince1970: 1_700_000_100), id: fixture.workspace.id)
    winner.sidebarOrderRevision = 2
    fixture.fake.setWorkspaces([winner])
    fixture.sync.reconcile(
      [winner], paneRecords: [], protectedLocalPaneIds: [], assignments: [:], serverId: fixture.serverId)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarOrderRevision == 1)
    fixture.sync.retryWorkspaceOrders(serverId: fixture.serverId, client: fixture.fake)
    await fixture.sync.workspaceOrderTasks[fixture.workspace.id]?.value
    let local = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(local.sidebarPosition == winner.sidebarPosition)
    #expect(local.pendingSidebarPosition == nil)
    #expect(fixture.fake.workspaces.first?.sidebarOrderRevision == 2)
  }

  @Test func aLostResponseDoesNotDiscardASubsequentLocalDrag() async throws {
    let fixture = WorkspaceEventFixture()
    let original = prepare(fixture)
    let server = OrderServer(record: original)
    let started = TestSignal()
    let release = TestSignal()
    fixture.fake.workspaceOrderHandler = { _, position, revision in
      _ = await server.move(position, revision: revision)
      started.signal()
      await release.wait()
      throw URLError(.networkConnectionLost)
    }
    let task = fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id], client: fixture.fake
    )
    await started.wait()
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.workspace.id, fixture.otherWorkspace.id], client: fixture.fake
    )
    let latest = try #require(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarPosition)
    release.signal()
    await task?.value
    fixture.fake.workspaceOrderHandler = { _, position, revision in
      await server.move(position, revision: revision)
    }
    fixture.sync.retryWorkspaceOrders(serverId: fixture.serverId, client: fixture.fake)
    await fixture.sync.workspaceOrderTasks[fixture.workspace.id]?.value
    let local = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(local.pendingSidebarPosition == nil)
    #expect(local.sidebarPosition == latest)
    #expect(local.sidebarOrderRevision == 3)
    #expect(await server.revisions() == [1, 1, 2])
  }

  @Test func layoutSavesCannotOverwritePendingOrConfirmedOrder() throws {
    let fixture = WorkspaceEventFixture()
    _ = prepare(fixture)
    let oldLayout = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id], client: nil
    )
    let pending = try #require(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarPosition)
    fixture.repository.save(oldLayout)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarPosition == pending)
    var confirmed = oldLayout
    confirmed.sidebarOrderRevision = 3
    confirmed.sidebarPosition = pending
    fixture.repository.saveWithSidebarOrder(confirmed)
    fixture.repository.save(oldLayout)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.sidebarPosition == pending)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.sidebarOrderRevision == 3)
  }

  @Test func confirmedPositionRejectsOlderMetadata() throws {
    let fixture = WorkspaceEventFixture()
    let old = prepare(fixture)
    var workspace = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    let newest = WorkspacePosition.initial(createdAt: Date(timeIntervalSince1970: 1_700_000_100), id: workspace.id)
    workspace.sidebarPosition = newest
    workspace.sidebarOrderRevision = 3
    WorkspaceSyncModel.applyMetadata(old, to: &workspace)
    #expect(workspace.sidebarPosition == newest)
    #expect(workspace.sidebarOrderRevision == 3)
  }

  @Test func pendingIntentPersistsAndRetriesAfterAnAmbiguousResponse() async throws {
    let fixture = WorkspaceEventFixture()
    let original = prepare(fixture)
    let server = OrderServer(record: original)
    fixture.fake.workspaceOrderHandler = { _, position, revision in
      _ = await server.move(position, revision: revision)
      throw URLError(.networkConnectionLost)
    }
    await fixture.sync.reorderWorkspace(
      id: fixture.workspace.id, visibleIDs: [fixture.otherWorkspace.id, fixture.workspace.id], client: fixture.fake
    )?.value
    let pending = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(pending))
    #expect(restored.pendingSidebarPosition == pending.pendingSidebarPosition)
    #expect(restored.pendingSidebarOrderRevision == 1)
    fixture.fake.workspaceOrderHandler = { _, position, revision in
      await server.move(position, revision: revision)
    }
    fixture.sync.retryWorkspaceOrders(serverId: fixture.serverId, client: fixture.fake)
    await fixture.sync.workspaceOrderTasks[fixture.workspace.id]?.value
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.pendingSidebarPosition == nil)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.sidebarOrderRevision == 2)
    #expect(await server.revisions() == [1, 1])
  }
}

private actor OrderServer {
  var record: ServerWorkspace
  var requestedRevisions: [Int] = []
  init(record: ServerWorkspace) { self.record = record }
  func count() -> Int { requestedRevisions.count }
  func revisions() -> [Int] { requestedRevisions }
  func move(_ position: String, revision: Int) -> ServerWorkspace {
    requestedRevisions.append(revision)
    if record.sidebarOrderRevision == revision {
      record.sidebarPosition = position
      record.sidebarOrderRevision = revision + 1
    }
    return record
  }
}
