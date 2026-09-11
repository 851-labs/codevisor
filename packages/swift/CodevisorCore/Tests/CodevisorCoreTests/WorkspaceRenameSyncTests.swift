import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct WorkspaceRenameSyncTests {
  @Test("A sidebar rename reaches the server without overwriting newer layout or archive state")
  func publishesNameOnly() async throws {
    let fixture = WorkspaceEventFixture()
    var serverRecord = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    serverRecord.isArchived = true
    _ = try await fixture.fake.upsertWorkspace(serverRecord)
    var current = fixture.workspace
    current.centerTabs.append(WorkspaceTab(root: .leaf(PaneGroupState())))
    fixture.repository.save(current)
    var renamed = fixture.workspace
    renamed.name = "Renamed on Mac"
    renamed.hasCustomName = true

    await fixture.sync.renameWorkspace(renamed, client: fixture.fake)?.value

    let local = try #require(fixture.repository.workspace(id: renamed.id))
    #expect(local.name == renamed.name)
    #expect(local.hasCustomName)
    #expect(local.centerTabs == current.centerTabs)
    let remote = try #require(try await fixture.fake.listWorkspaces()?.first)
    #expect(remote.name == renamed.name)
    #expect(remote.hasCustomName)
    #expect(remote.isArchived)
    #expect(fixture.sync.revision == 1)
  }

  @Test("A snapshot started before a rename cannot revert its local name")
  func supersedesEarlierSnapshot() async {
    let fixture = WorkspaceEventFixture()
    let started = TestSignal()
    let release = TestSignal()
    let snapshot = ServerWorkspaceSnapshot(
      workspaces: [WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)], panes: []
    )
    fixture.fake.workspaceSnapshotHandler = {
      started.signal()
      await release.wait()
      return snapshot
    }
    let refresh = Task {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    await started.wait()
    var renamed = fixture.workspace
    renamed.name = "New name"
    renamed.hasCustomName = true
    fixture.sync.renameWorkspace(renamed, client: nil)
    release.signal()

    #expect(await refresh.value == .superseded)
    #expect(fixture.repository.workspace(id: renamed.id)?.name == renamed.name)
  }
}
