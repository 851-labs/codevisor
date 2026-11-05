import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationEventRecoveryTests {
  @Test("A failed snapshot keeps the cached state, shows it stale, and the machine reconnects until one lands")
  func workspaceSnapshotRecovery() async throws {
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let fixture = await WorkspaceEventFixture(connectionScheduler: scheduler.scheduler)
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let other = fixture.repository.workspace(id: fixture.otherWorkspace.id)
    let connection = fixture.controller.connection(for: fixture.serverId)

    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: fixture.fake, presentation: .catchUp
    )
    await awaitObserved { connection.availability?.isFailed == true }

    guard case .stale = connection.navigationSyncState else {
      Issue.record("A failed snapshot must not be presented as current")
      return
    }
    #expect(fixture.fake.workspaceSnapshotCallCount == 2)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == false)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.centerTabs == fixture.workspace.centerTabs)

    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    await awaitObserved { scheduler.requestedIntervals.contains(MachineReconnector.baseDelay) }
    scheduler.advance()
    await awaitObserved { connection.navigationSyncState == .current }

    #expect(connection.availability == .ready)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == other)
    await fixture.stop()
  }

  @Test("An unreadable navigation event recovers the change through one snapshot without reconnecting")
  func eventRefreshRecovery() async throws {
    let clock = TestClock()
    let fixture = await WorkspaceEventFixture(navigationClock: clock)
    defer { fixture.controller.stopEventSync() }
    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    let connection = fixture.controller.connection(for: fixture.serverId)
    connection.navigationSyncState = .current

    fixture.fake.emit(kind: "navigation.changed", subjectId: fixture.workspace.id.uuidString)
    await clock.waitForSleep(.milliseconds(300))
    guard case .stale = connection.navigationSyncState else {
      Issue.record("The failed event must report stale navigation")
      return
    }
    let refresh = try #require(connection.navigationSync.pendingRefreshTask)
    clock.advance(by: .milliseconds(300))
    await refresh.value

    #expect(connection.navigationSyncState == .current)
    #expect(connection.availability == .ready)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await fixture.stop()
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
    let refresh = try #require(fixture.controller.connection(for: fixture.serverId).navigationSync.pendingRefreshTask)
    clock.advance(by: .milliseconds(300))
    await refresh.value
    #expect(fixture.store.hasCache(for: fixture.serverId))
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await fixture.stop()
  }

  @Test("Ended and failed shell streams reconnect the machine at once", arguments: [false, true])
  func endedStreamRecovers(fails: Bool) async throws {
    let fixture = await WorkspaceEventFixture()
    defer { fixture.controller.stopEventSync() }
    let snapshot = fixture.archivedSnapshot()
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let handled = TestSignal()
    fixture.controller.onMcpStateChanged = { _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    fixture.fake.emit(kind: "mcp.updated", subjectId: "event-barrier")
    await handled.wait()
    let connection = fixture.controller.connection(for: fixture.serverId)
    let stream = try #require(connection.navigationSync.eventStreamTask)

    fixture.fake.finishEventStreams(throwing: fails ? URLError(.networkConnectionLost) : nil)
    await stream.value
    await awaitObserved { connection.navigationSyncState == .current }
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    fixture.fake.emit(kind: "mcp.updated", subjectId: "reconnected-barrier")
    await handled.wait(for: 2)

    #expect(connection.navigationSyncState == .current)
    #expect(connection.availability == .ready)
    await fixture.stop()
  }

  @Test("Removing a machine cancels its scheduled reconnect")
  func removedMachineDoesNotRetry() async throws {
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let fixture = await WorkspaceEventFixture(connectionScheduler: scheduler.scheduler)
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    defer { fixture.controller.stopEventSync() }
    let connection = fixture.controller.connection(for: fixture.serverId)
    await fixture.controller.synchronizeNavigationState(
      serverId: fixture.serverId, client: fixture.fake, presentation: .background
    )
    await awaitObserved { scheduler.requestedIntervals.contains(MachineReconnector.baseDelay) }

    fixture.controller.removeConnection(for: fixture.serverId)
    scheduler.advance()

    #expect(!connection.reconnector.isActive)
    #expect(fixture.fake.workspaceSnapshotCallCount == 2)
    #expect(fixture.controller.connectionsById[fixture.serverId] == nil)
  }

  @Test("A timed-out snapshot cannot hold the reconnect or overwrite its result")
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
    let connection = fixture.controller.connection(for: fixture.serverId)
    await awaitObserved { connection.navigationSyncState == .current }
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)

    release.signal()
    await original.value
    #expect(connection.navigationSyncState == .current)
    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    await fixture.stop()
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

extension ServerAvailability {
  fileprivate var isFailed: Bool {
    guard case .failed = self else { return false }
    return true
  }
}
