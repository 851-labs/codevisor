import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Workspace changes from other devices arrive on a machine's event stream as
/// `navigation.changed` deltas and move this device's cached copy forward.
@MainActor
@Suite("MachineController workspace events", .timeLimit(.minutes(1)))
struct MachineControllerWorkspaceEventTests {
  @Test("Remote workspace archive and restore events apply even when snapshots fail")
  func workspaceMetadataEventsSurviveSnapshotFailure() async throws {
    let fixture = await WorkspaceEventFixture()
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    defer { fixture.controller.stopEventSync() }
    #expect(fixture.routeDisposition == .keep)
    let other = fixture.repository.workspace(id: fixture.otherWorkspace.id)

    for (index, archived) in [true, false].enumerated() {
      let revision = fixture.sync.revision
      fixture.fake.emit(
        kind: "workspace.updated", subjectId: fixture.workspace.id.uuidString.lowercased(),
        payload: fixture.payload(isArchived: archived, name: "Renamed on Mac")
      )
      // The next event's callback acknowledges completion of the workspace event.
      fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
      await handled.wait(for: index + 1)

      let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id))
      #expect(updated.isArchived == archived)
      #expect(updated.name == "Renamed on Mac")
      #expect(updated.centerTabs == fixture.workspace.centerTabs)
      #expect(updated.serverId == fixture.serverId)
      #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == other)
      #expect(fixture.sync.revision != revision)
      #expect(fixture.routeDisposition == (archived ? .dismiss : .keep))
    }
    #expect(fixture.fake.workspaceSnapshotCallCount == 0)
  }

  @Test("Workspace events supersede a snapshot that was already in flight", arguments: [true, false])
  func workspaceEventSupersedesSnapshot(isArchived: Bool) async throws {
    let fixture = await WorkspaceEventFixture()
    let started = TestSignal()
    let release = TestSignal()
    var staleRecord = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    staleRecord.isArchived = !isArchived
    let staleSnapshot = ServerWorkspaceSnapshot(workspaces: [staleRecord], panes: fixture.fake.workspacePanes ?? [])
    fixture.fake.workspaceSnapshotHandler = {
      started.signal()
      await release.wait()
      return staleSnapshot
    }
    let refresh = Task {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    defer {
      release.signal()
      refresh.cancel()
    }
    await started.wait()

    var record = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    record.isArchived = isArchived
    #expect(await fixture.store.apply(.fixture(cursor: 1, workspaces: [record]), machineId: fixture.serverId))
    release.signal()
    #expect(await refresh.value == .committed)

    let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(updated.isArchived == isArchived)
    #expect(updated.centerTabs == fixture.workspace.centerTabs)
  }

  @Test("Workspace deltas materialize unknown workspaces without another request", arguments: [true, false])
  func workspaceEventMaterializes(unknownWorkspace: Bool) async throws {
    let fixture = await WorkspaceEventFixture(cachesWorkspace: !unknownWorkspace)
    #expect((fixture.repository.workspace(id: fixture.workspace.id) == nil) == unknownWorkspace)
    let other = fixture.repository.workspace(id: fixture.otherWorkspace.id)
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    defer { fixture.controller.stopEventSync() }

    fixture.fake.emit(
      kind: "workspace.updated", subjectId: fixture.workspace.id.uuidString,
      payload: fixture.payload(isArchived: true, name: "Shared")
    )
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()

    let workspace = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(workspace.isArchived)
    #expect(workspace.isServerSynced)
    #expect(fixture.fake.workspaceSnapshotCallCount == 0)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == other)
  }

  @Test("A machine's events change only that machine's workspaces")
  func eventsAreScopedToTheirMachine() async throws {
    let fixture = await WorkspaceEventFixture()
    let before = fixture.repository.workspace(id: fixture.workspace.id)
    var record = WorkspaceSyncModel.serverWorkspace(from: fixture.otherWorkspace)
    record.isArchived = true
    #expect(await fixture.store.apply(.fixture(cursor: 1, workspaces: [record]), machineId: "another-mac"))
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id)?.isArchived == true)
    #expect(fixture.repository.workspace(id: fixture.workspace.id) == before)
    #expect(fixture.store.eventCursor(for: fixture.serverId) == 0)
    // A machine this device has no cache for asks for a snapshot instead.
    #expect(!(await fixture.store.apply(.fixture(cursor: 1, workspaces: [record]), machineId: "unknown-mac")))
  }
}
