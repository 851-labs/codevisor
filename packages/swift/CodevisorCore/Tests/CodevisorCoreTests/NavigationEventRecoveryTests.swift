import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationEventRecoveryTests {
  @Test("Failed workspace snapshots stay stale and retry with backoff without another event")
  func workspaceSnapshotRecovery() async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }

    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: fixture.fake, presentation: .catchUp
    )
    let connection = fixture.controller.connection(for: fixture.serverId)
    guard case .stale = connection.navigationSyncState else {
      Issue.record("A failed workspace snapshot must not be presented as current")
      return
    }
    #expect(fixture.repository.workspace(id: fixture.workspace.id) == fixture.workspace)
    #expect(fixture.fake.workspaceSnapshotCallCount == 1)
    await clock.waitForSleep(.seconds(2))
    let firstRetry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(2))
    await firstRetry.value
    #expect(fixture.fake.workspaceSnapshotCallCount == 2)
    guard case .stale = connection.navigationSyncState else {
      Issue.record("A failed retry must retain the stale state")
      return
    }

    await clock.waitForSleep(.seconds(4))
    let snapshot = archivedSnapshot(fixture)
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let secondRetry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(4))
    await secondRetry.value

    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == fixture.otherWorkspace)
    #expect(connection.navigationRetryTask == nil)
    await stop(fixture)
    #expect(clock.pendingCount == 0)
  }

  @Test(
    "Navigation event refresh failures recover without losing the consumed event",
    arguments: [
      "workspace.updated", "workspace.pane.updated", "workspace.pane.deleted",
      "project.created", "project.updated", "worktree.created",
      "session.created", "session.updated", "session.attention.updated",
      "session.archived", "session.unarchived",
    ])
  func eventRefreshRecovery(kind: String) async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    let connection = fixture.controller.connection(for: fixture.serverId)
    connection.navigationSyncState = .current
    fixture.fake.emit(kind: kind, subjectId: fixture.workspace.id.uuidString)
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()

    if !kind.hasPrefix("workspace.") {
      await clock.waitForSleep(.milliseconds(300))
      let refresh = try #require(connection.pendingRefreshTask)
      clock.advance(by: .milliseconds(300))
      await refresh.value
    }
    guard case .stale = connection.navigationSyncState else {
      Issue.record("The failed event refresh must report stale navigation")
      return
    }
    await clock.waitForSleep(.seconds(2))
    let snapshot = archivedSnapshot(fixture)
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let retry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(2))
    await retry.value

    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(connection.navigationRetryTask == nil)
    await stop(fixture)
    #expect(clock.pendingCount == 0)
  }

  @Test("Ended and failed shell streams reconnect through navigation recovery", arguments: [false, true])
  func endedStreamRecovers(fails: Bool) async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    defer { fixture.controller.stopEventSync() }
    let snapshot = archivedSnapshot(fixture)
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()
    let connection = fixture.controller.connection(for: fixture.serverId)
    let stream = try #require(connection.eventSyncTask)
    fixture.fake.finishEventStreams(throwing: fails ? URLError(.networkConnectionLost) : nil)
    await stream.value

    await clock.waitForSleep(.seconds(2))
    let retry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(2))
    await retry.value
    fixture.fake.emit(kind: "plugin.updated", subjectId: "reconnected-barrier")
    await handled.wait(for: 2)
    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await stop(fixture)
    #expect(clock.pendingCount == 0)
  }

  @Test("Removing a machine cancels its scheduled navigation recovery")
  func removedMachineDoesNotRetry() async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    defer { fixture.controller.stopEventSync() }
    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: fixture.fake, presentation: .background
    )
    await clock.waitForSleep(.seconds(2))
    let retry = try #require(fixture.controller.connection(for: fixture.serverId).navigationRetryTask)
    fixture.controller.removeConnection(for: fixture.serverId)
    await retry.value
    clock.advance(by: .seconds(60))
    #expect(fixture.fake.workspaceSnapshotCallCount == 1)
    #expect(fixture.controller.connectionsById[fixture.serverId] == nil)
  }

  @Test("A timed-out snapshot cannot hold retries or overwrite their result")
  func stalledSnapshotLosesOwnership() async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    let started = TestSignal()
    let release = TestSignal()
    let stale = ServerWorkspaceSnapshot(
      workspaces: [WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)], panes: []
    )
    let fresh = archivedSnapshot(fixture)
    fixture.fake.workspaceSnapshotHandler = {
      started.signal()
      if started.value == 1 {
        // Like a wedged transport, this deliberately ignores cancellation.
        await release.wait()
        return stale
      }
      return fresh
    }
    let original = Task {
      await fixture.controller.synchronizeNavigationState(
        serverId: fixture.serverId, client: fixture.fake, presentation: .catchUp
      )
    }
    defer {
      release.signal()
      original.cancel()
      fixture.controller.stopEventSync()
    }
    await started.wait()
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))
    await clock.waitForSleep(.seconds(2))
    let connection = fixture.controller.connection(for: fixture.serverId)
    let retry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(2))
    await retry.value
    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)

    release.signal()
    await original.value
    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await stop(fixture)
    #expect(clock.pendingCount == 0)
  }

  @Test("Older servers without workspace endpoints still finish navigation sync")
  func olderServerCompatibility() async {
    let fixture = WorkspaceEventFixture()
    defer { fixture.controller.stopEventSync() }
    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: FakeServerClient(), presentation: .background
    )
    #expect(fixture.controller.connection(for: fixture.serverId).navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id) == fixture.workspace)
  }

  private func archivedSnapshot(_ fixture: WorkspaceEventFixture) -> ServerWorkspaceSnapshot {
    var workspace = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    workspace.isArchived = true
    return ServerWorkspaceSnapshot(workspaces: [workspace], panes: [])
  }

  private func stop(_ fixture: WorkspaceEventFixture) async {
    let connection = fixture.controller.connection(for: fixture.serverId)
    let tasks = [
      connection.eventSyncTask, connection.navigationRetryTask, connection.navigationSyncTask,
      connection.pendingRefreshTask,
    ].compactMap { $0 }
    fixture.controller.stopEventSync()
    for task in tasks { await task.value }
  }
}
