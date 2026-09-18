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
    // Newer layout is real content the server already knows about; an empty
    // tab is only ever a placeholder and is retired once real panes exist.
    var current = fixture.workspace
    var newTabGroup = PaneGroupState()
    let newTab = newTabGroup.addNewTabPane()
    current.centerTabs.append(WorkspaceTab(root: .leaf(newTabGroup)))
    fixture.repository.save(current)
    _ = try await fixture.fake.upsertWorkspacePane(
      WorkspaceSyncModel.serverPane(from: newTab, workspaceId: current.id, createdAt: current.createdAt))
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

  @Test("A snapshot started before a confirmed rename cannot revert its name")
  func supersedesEarlierSnapshot() async {
    let fixture = WorkspaceEventFixture()
    fixture.fake.setWorkspaces([WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)])
    let started = TestSignal()
    let release = TestSignal()
    let snapshot = ServerWorkspaceSnapshot(
      workspaces: [WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)], panes: []
    )
    fixture.fake.workspaceSnapshotHandler = {
      if started.value == 0 {
        started.signal()
        await release.wait()
        return snapshot
      }
      return nil
    }
    let refresh = Task {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    defer { release.signal(); refresh.cancel() }
    await started.wait()
    var renamed = fixture.workspace
    renamed.name = "New name"
    renamed.hasCustomName = true
    await fixture.sync.renameWorkspace(renamed, client: fixture.fake)?.value
    release.signal()

    #expect(await refresh.value == .superseded)
    #expect(fixture.repository.workspace(id: renamed.id)?.name == renamed.name)
  }

  @Test("A failed rename reports an error and retains the server name", arguments: [false, true])
  func failedRename(lostAcknowledgement: Bool) async throws {
    let fixture = WorkspaceEventFixture()
    let reporter = ErrorReporter()
    defer { reporter.dismissAll() }
    let record = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    fixture.fake.setWorkspaces([record])
    let fake = fixture.fake
    fake.workspaceRenameHandler = { _, name, custom in
      if lostAcknowledgement {
        var saved = record
        saved.name = name
        saved.hasCustomName = custom
        fake.setWorkspaces([saved])
      }
      throw URLError(.networkConnectionLost)
    }
    defer { fake.workspaceRenameHandler = nil }
    var renamed = fixture.workspace
    renamed.name = "Shared rename"
    renamed.hasCustomName = true
    await fixture.sync.renameWorkspace(renamed, client: fake, errorReporter: reporter)?.value

    let expected = lostAcknowledgement ? renamed.name : fixture.workspace.name
    #expect(fixture.repository.workspace(id: renamed.id)?.name == expected)
    #expect(fake.workspaces.first?.name == expected)
    #expect(reporter.entries.map(\.title) == ["Couldn't Rename Workspace"])
  }

  @Test("Without a client a rename reports failure instead of saving locally")
  func noClient() {
    let fixture = WorkspaceEventFixture()
    let reporter = ErrorReporter()
    defer { reporter.dismissAll() }
    var renamed = fixture.workspace
    renamed.name = "Only here"
    #expect(fixture.sync.renameWorkspace(renamed, client: nil, errorReporter: reporter) == nil)
    #expect(fixture.repository.workspace(id: renamed.id) == fixture.workspace)
    #expect(reporter.entries.count == 1)
  }

  @Test("Renames are serialized and the most recent queued name wins")
  func serializesRenames() async {
    let fixture = WorkspaceEventFixture()
    fixture.fake.setWorkspaces([WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)])
    let started = TestSignal()
    let release = TestSignal()
    fixture.fake.workspaceRenameHandler = { _, name, _ in
      if name == "First" { started.signal(); await release.wait() }
    }
    var renamed = fixture.workspace
    renamed.name = "First"
    renamed.hasCustomName = true
    let task = fixture.sync.renameWorkspace(renamed, client: fixture.fake)
    defer { release.signal(); task?.cancel() }
    await started.wait()
    #expect(fixture.repository.workspace(id: renamed.id)?.name == fixture.workspace.name)
    renamed.name = "Intermediate"
    fixture.sync.renameWorkspace(renamed, client: fixture.fake)
    renamed.name = "Latest"
    fixture.sync.renameWorkspace(renamed, client: fixture.fake)
    #expect(fixture.fake.workspaceRenameNames == ["First"])
    release.signal()
    await task?.value
    #expect(fixture.fake.workspaceRenameNames == ["First", "Latest"])
    #expect(fixture.fake.workspaces.first?.name == "Latest")
    #expect(fixture.repository.workspace(id: renamed.id)?.name == "Latest")
  }

  @Test("A workspace is published before renaming its server record")
  func publishesUnadoptedWorkspace() async {
    let fixture = WorkspaceEventFixture()
    var local = fixture.workspace
    local.isServerSynced = false
    local.centerTabs = [WorkspaceTab(root: .leaf(PaneGroupState()))]
    fixture.repository.save(local)
    var renamed = local
    renamed.name = "Published"
    renamed.hasCustomName = true
    await fixture.sync.renameWorkspace(renamed, client: fixture.fake)?.value
    #expect(fixture.fake.workspaces.first?.name == renamed.name)
    #expect(fixture.repository.workspace(id: renamed.id)?.name == renamed.name)
    #expect(fixture.repository.workspace(id: renamed.id)?.isServerSynced == true)
  }

  @Test("Authoritative names replace old local aliases in events and snapshots", arguments: [false, true])
  func replacesLocalAlias(event: Bool) async {
    let fixture = WorkspaceEventFixture()
    var local = fixture.workspace
    local.name = "Old device-only name"
    local.hasCustomName = true
    fixture.repository.saveWithSidebarOrder(local)
    if event {
      #expect(fixture.sync.applyServerWorkspaceEvent(fixture.event(isArchived: false), serverId: fixture.serverId))
    } else {
      fixture.fake.setWorkspaces([WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)])
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    #expect(fixture.repository.workspace(id: local.id)?.name == fixture.workspace.name)
    #expect(fixture.repository.workspace(id: local.id)?.hasCustomName == false)
  }

  @Test("A stale layout save cannot restore the name from before a remote rename")
  func staleLayoutPreservesServerName() throws {
    let fixture = WorkspaceEventFixture()
    var stale = fixture.workspace
    var event = fixture.event(isArchived: false)
    event.payload = fixture.payload(isArchived: false, name: "Server name")
    #expect(fixture.sync.applyServerWorkspaceEvent(event, serverId: fixture.serverId))
    stale.centerTabs.append(WorkspaceTab(root: .leaf(PaneGroupState())))
    fixture.repository.save(stale)
    let saved = try #require(fixture.repository.workspace(id: stale.id))
    #expect(saved.name == "Server name")
    #expect(saved.hasCustomName)
    #expect(saved.centerTabs == stale.centerTabs)
  }

  @Test("A legacy workspace renames its existing server identity instead of creating a duplicate")
  func renamesCanonicalWorkspace() async {
    let fixture = WorkspaceEventFixture()
    var local = fixture.workspace
    local.isServerSynced = false
    fixture.repository.save(local)
    let canonicalId = UUID()
    var record = WorkspaceSyncModel.serverWorkspace(from: local)
    record.id = canonicalId.uuidString
    fixture.fake.setWorkspaces([record])
    let list = fixture.sync.projectList
    var chat = serverSession(from: list.sessions[0])
    chat.workspaceId = canonicalId.uuidString
    fixture.fake.setSessions([chat])
    list.workspaceAssignmentsByServer[fixture.serverId] = [fixture.anchorSessionId: canonicalId]
    var renamed = local
    renamed.name = "Canonical name"
    renamed.hasCustomName = true
    await fixture.sync.renameWorkspace(renamed, client: fixture.fake)?.value
    #expect(fixture.fake.workspaces.count == 1)
    #expect(fixture.fake.workspaces.first?.id == canonicalId.uuidString)
    #expect(fixture.fake.workspaces.first?.name == renamed.name)
    #expect(fixture.repository.workspace(id: canonicalId)?.name == renamed.name)
    #expect(fixture.repository.workspace(id: local.id) == nil)
  }
}
