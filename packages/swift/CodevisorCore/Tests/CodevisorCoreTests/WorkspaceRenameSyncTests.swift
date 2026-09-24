import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct WorkspaceRenameSyncTests {
  private func renamed(_ fixture: WorkspaceSyncFixture, _ name: String) -> Workspace {
    var workspace = fixture.workspace
    workspace.name = name
    workspace.hasCustomName = true
    return workspace
  }

  @Test("A sidebar rename reaches the server without touching layout or archive state")
  func publishesNameOnly() async throws {
    let fixture = await WorkspaceSyncFixture { workspace, _ in workspace.isArchived = true }
    // This device's own ⌘T page: never on the server, and a rename must not lose it.
    var layout = try #require(fixture.current)
    var group = PaneGroupState()
    group.addNewTabPane()
    layout.centerTabs.append(WorkspaceTab(root: .leaf(group)))
    fixture.repository.save(layout)

    fixture.sync.renameWorkspace(renamed(fixture, "Renamed on Mac"))

    // Shown immediately, before any request.
    let local = try #require(fixture.current)
    #expect(local.name == "Renamed on Mac")
    #expect(local.hasCustomName)
    #expect(local.isArchived)
    #expect(local.centerTabs == layout.centerTabs)

    fixture.connect()
    await fixture.settle()
    let remote = try fixture.serverRecord(fixture.workspace.id)
    #expect(remote.name == "Renamed on Mac")
    #expect(remote.hasCustomName)
    #expect(remote.isArchived)
    #expect(fixture.server.requests == ["rename:Renamed on Mac"])
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == "Renamed on Mac")
    #expect(fixture.current?.centerTabs == layout.centerTabs)
  }

  @Test("A snapshot fetched before a rename was accepted cannot revert its name")
  func supersedesEarlierSnapshot() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    let stale = fixture.server.current
    let fetchedAt = Date(timeIntervalSinceNow: -60)
    fixture.sync.renameWorkspace(renamed(fixture, "New name"))
    await fixture.flush()
    // Accepted, but its event hasn't arrived: the entry waits for it.
    #expect(fixture.store.pendingIntents.count == 1)

    await fixture.store.replace(stale, machineId: fixture.serverId, requestedAt: fetchedAt, resetsStream: false)
    #expect(fixture.current?.name == "New name")

    await fixture.deliver()
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == "New name")
  }

  @Test("A snapshot fetched after the rename was accepted retires it")
  func laterSnapshotRetires() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    fixture.sync.renameWorkspace(renamed(fixture, "New name"))
    await fixture.flush()
    let result = await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.server)
    #expect(result == .committed)
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == "New name")
  }

  @Test("A refused rename falls back to the server's name")
  func refusedRename() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    fixture.server.onRequest { _ in throw CodevisorServerClientError.httpStatus(422, "Invalid name") }
    fixture.sync.renameWorkspace(renamed(fixture, "Refused"))
    #expect(fixture.current?.name == "Refused")
    await fixture.flush()
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == fixture.workspace.name)
    #expect(try fixture.serverRecord(fixture.workspace.id).name == fixture.workspace.name)
  }

  @Test("A rename that loses its connection stays shown and is sent again", arguments: [false, true])
  func retriesAfterTransportFailure(lostAcknowledgement: Bool) async throws {
    let clock = TestClock()
    let fixture = await WorkspaceSyncFixture(clock: clock, connected: true)
    let server = fixture.server
    let workspaceId = fixture.workspace.id
    let failures = TestSignal()
    server.onRequest { _ in
      guard failures.value == 0 else { return }
      failures.signal()
      if lostAcknowledgement, var record = server.workspace(workspaceId) {
        record.name = "Shared rename"
        record.hasCustomName = true
        server.commit(workspaces: [record])
      }
      throw URLError(.networkConnectionLost)
    }
    fixture.sync.renameWorkspace(renamed(fixture, "Shared rename"))
    await fixture.flush()
    #expect(fixture.store.pendingIntents.count == 1)
    #expect(fixture.current?.name == "Shared rename")

    // The machine comes back: the same request is sent again, safely.
    await fixture.settle()
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == "Shared rename")
    #expect(try fixture.serverRecord(fixture.workspace.id).name == "Shared rename")
    #expect(server.requests == ["rename:Shared rename", "rename:Shared rename"])
  }

  @Test("Offline, a rename waits in the outbox and is sent when the machine is current")
  func offlineRenameWaits() async throws {
    let fixture = await WorkspaceSyncFixture()
    fixture.sync.renameWorkspace(renamed(fixture, "Only here for now"))
    #expect(fixture.current?.name == "Only here for now")
    #expect(fixture.server.requests.isEmpty)
    #expect(
      fixture.store.pendingIntents.map(\.intent) == [
        .renameWorkspace(workspaceId: fixture.workspace.id, name: "Only here for now", hasCustomName: true)
      ])

    fixture.connect()
    await fixture.settle()
    #expect(try fixture.serverRecord(fixture.workspace.id).name == "Only here for now")
  }

  @Test("Blank names are ignored")
  func blankNameIgnored() async {
    let fixture = await WorkspaceSyncFixture()
    #expect(fixture.sync.renameWorkspace(renamed(fixture, "   ")) == nil)
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == fixture.workspace.name)
  }

  @Test("Unsent renames coalesce behind the one in flight, and the latest name wins")
  func serializesRenames() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    let started = TestSignal()
    let release = TestSignal()
    fixture.server.onRequest { name in
      if name == "rename:First" {
        started.signal()
        await release.wait()
      }
    }
    fixture.sync.renameWorkspace(renamed(fixture, "First"))
    await started.wait()
    fixture.sync.renameWorkspace(renamed(fixture, "Intermediate"))
    fixture.sync.renameWorkspace(renamed(fixture, "Latest"))
    #expect(fixture.current?.name == "Latest")
    #expect(fixture.store.pendingIntents.count == 2)
    release.signal()
    await fixture.settle()
    #expect(fixture.server.requests == ["rename:First", "rename:Latest"])
    #expect(try fixture.serverRecord(fixture.workspace.id).name == "Latest")
    #expect(fixture.current?.name == "Latest")
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("A draft workspace is renamed on this device without a request")
  func draftRenamesLocally() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    let draft = fixture.repository.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: UUID(), initialName: "Draft", serverId: fixture.serverId, projectId: fixture.project.id,
        rootDirectory: nil),
      legacyGroups: nil)
    #expect(draft.isDraft)
    var renamed = draft
    renamed.name = "Published later"
    renamed.hasCustomName = true
    fixture.sync.renameWorkspace(renamed)
    await fixture.flush()
    #expect(fixture.repository.workspace(id: draft.id)?.name == "Published later")
    #expect(fixture.store.layouts.draft(id: draft.id)?.name == "Published later")
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.server.requests.isEmpty)
  }

  @Test("Server names replace this device's, from events and from snapshots", arguments: [false, true])
  func serverNameWins(event: Bool) async throws {
    let fixture = await WorkspaceSyncFixture()
    var record = try fixture.serverRecord(fixture.workspace.id)
    record.name = "Named elsewhere"
    record.hasCustomName = true
    fixture.server.commit(workspaces: [record])
    if event {
      await fixture.deliver()
    } else {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.server)
    }
    #expect(fixture.current?.name == "Named elsewhere")
    #expect(fixture.current?.hasCustomName == true)
  }

  @Test("A stale layout save cannot restore the name from before a remote rename")
  func staleLayoutPreservesServerName() async throws {
    let fixture = await WorkspaceSyncFixture()
    var stale = try #require(fixture.current)
    var record = try fixture.serverRecord(fixture.workspace.id)
    record.name = "Server name"
    record.hasCustomName = true
    fixture.server.commit(workspaces: [record])
    await fixture.deliver()

    stale.centerTabs.append(WorkspaceTab(root: .leaf(PaneGroupState.centerInitialWithoutChat())))
    fixture.repository.save(stale)
    let saved = try #require(fixture.current)
    #expect(saved.name == "Server name")
    #expect(saved.hasCustomName)
    #expect(saved.centerTabs == stale.centerTabs)
    #expect(fixture.store.pendingIntents.isEmpty)
  }
}
