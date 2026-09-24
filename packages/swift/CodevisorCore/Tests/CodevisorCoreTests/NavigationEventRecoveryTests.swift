import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationEventRecoveryTests {
  @Test("Failed snapshots keep the cached state, stay stale, and retry with backoff without another event")
  func workspaceSnapshotRecovery() async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let other = fixture.repository.workspace(id: fixture.otherWorkspace.id)

    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: fixture.fake, presentation: .catchUp
    )
    let connection = fixture.controller.connection(for: fixture.serverId)
    guard case .stale = connection.navigationSyncState else {
      Issue.record("A failed snapshot must not be presented as current")
      return
    }
    // The last known state stays on screen while the machine is unreachable.
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == false)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.centerTabs == fixture.workspace.centerTabs)
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
    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let secondRetry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(4))
    await secondRetry.value

    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == other)
    #expect(connection.navigationRetryTask == nil)
    await fixture.stop()
    #expect(clock.pendingCount == 0)
  }

  @Test("An unreadable navigation event recovers through a snapshot without losing the change")
  func eventRefreshRecovery() async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    let connection = fixture.controller.connection(for: fixture.serverId)
    connection.navigationSyncState = .current
    fixture.fake.emit(kind: "navigation.changed", subjectId: fixture.workspace.id.uuidString)
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()

    guard case .stale = connection.navigationSyncState else {
      Issue.record("The failed event must report stale navigation")
      return
    }
    await clock.waitForSleep(.seconds(2))
    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let retry = try #require(connection.navigationRetryTask)
    clock.advance(by: .seconds(2))
    await retry.value

    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(connection.navigationRetryTask == nil)
    await fixture.stop()
    #expect(clock.pendingCount == 0)
  }

  @Test("A delta for a machine with no cache schedules a snapshot instead of guessing")
  func deltaWithoutCacheRefreshes() async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    defer { fixture.controller.stopEventSync() }
    fixture.store.forget(machineId: fixture.serverId)
    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    fixture.fake.emit(
      kind: "workspace.updated", subjectId: fixture.workspace.id.uuidString,
      payload: fixture.payload(isArchived: true, name: fixture.workspace.name))

    await clock.waitForSleep(.milliseconds(300))
    let refresh = try #require(fixture.controller.connection(for: fixture.serverId).pendingRefreshTask)
    clock.advance(by: .milliseconds(300))
    await refresh.value
    #expect(fixture.store.hasCache(for: fixture.serverId))
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await fixture.stop()
  }

  @Test("Ended and failed shell streams reconnect through navigation recovery", arguments: [false, true])
  func endedStreamRecovers(fails: Bool) async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    defer { fixture.controller.stopEventSync() }
    let snapshot = fixture.archivedSnapshot()
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
    await fixture.stop()
    #expect(clock.pendingCount == 0)
  }

  @Test("Removing a machine cancels its scheduled navigation recovery")
  func removedMachineDoesNotRetry() async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
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
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    let started = TestSignal()
    let release = TestSignal()
    let stale = FakeWorkspaceSnapshot(
      workspaces: [WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)], panes: []
    )
    let fresh = fixture.archivedSnapshot()
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
    await fixture.stop()
    #expect(clock.pendingCount == 0)
  }

  @Test("An empty authoritative snapshot removes vanished server workspaces")
  func emptySnapshotRemovesWorkspaces() async {
    let fixture = await WorkspaceEventFixture()
    defer { fixture.controller.stopEventSync() }
    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: SyncFakeServerClient(projects: [], sessions: []),
      presentation: .background
    )
    #expect(fixture.controller.connection(for: fixture.serverId).navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id) == nil)
    #expect(fixture.store.layouts.layout(for: fixture.workspace.id) == nil)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) != nil)
    await fixture.stop()
  }
}
