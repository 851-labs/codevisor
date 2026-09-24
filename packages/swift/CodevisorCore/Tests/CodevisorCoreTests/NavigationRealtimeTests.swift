import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Live `navigation.changed` deltas against this device's own waiting
/// changes: a delta moves the cached server state forward in one step, and
/// the outbox's requests stay laid over it until the server's copy carries
/// them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationRealtimeTests {
  @Test("A delta that archives a workspace flips it in one step")
  func archiveDeltaAppliesInOneStep() async throws {
    let fixture = await WorkspaceSyncFixture()
    var record = try fixture.serverRecord(fixture.workspace.id)
    record.isArchived = true
    record.archivedAt = "2026-09-23T00:00:00.000Z"
    let revision = fixture.sync.revision

    let applied = await fixture.store.apply(.fixture(cursor: 2, workspaces: [record]), machineId: fixture.serverId)

    #expect(applied)
    #expect(fixture.current?.isArchived == true)
    #expect(fixture.repository.loadAll().first { $0.id == fixture.workspace.id }?.isArchived == true)
    #expect(fixture.current?.centerTabs == fixture.workspace.centerTabs)
    #expect(fixture.sync.revision != revision)
    #expect(fixture.store.eventCursor(for: fixture.serverId) == 2)

    // Restoring it is the same single step.
    record.isArchived = false
    record.archivedAt = nil
    _ = await fixture.store.apply(.fixture(cursor: 3, workspaces: [record]), machineId: fixture.serverId)
    #expect(fixture.current?.isArchived == false)
  }

  @Test("A delta that deletes a pane removes it from this device's layout in one step")
  func paneDeletionDeltaUpdatesLayout() async throws {
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "shell")
    let fixture = await WorkspaceSyncFixture { workspace, _ in
      workspace.centerTabs.append(
        WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))))
    }
    #expect(fixture.current?.tabId(containingPane: terminal.id) != nil)

    _ = await fixture.store.apply(
      .fixture(cursor: 2, deleted: [("workspace_panes", terminal.id.uuidString)]), machineId: fixture.serverId)

    let workspace = try #require(fixture.current)
    #expect(workspace.tabId(containingPane: terminal.id) == nil)
    #expect(workspace.centerTabs.count == 1)
    #expect(workspace.pane(containingChat: fixture.anchorSessionId) != nil)
    let layout = try #require(fixture.store.layouts.layout(for: fixture.workspace.id))
    #expect(layout.tabs == workspace.centerTabs)
    #expect(!layout.tabs.flatMap { $0.root.allGroups }.contains { $0.state.panes.contains { $0.id == terminal.id } })
  }

  @Test("An unsent rename survives unrelated deltas, including one carrying the old record")
  func pendingRenameSurvivesUnrelatedDeltas() async throws {
    let fixture = await WorkspaceSyncFixture()
    var renamed = fixture.workspace
    renamed.name = "Renamed here"
    renamed.hasCustomName = true
    fixture.sync.renameWorkspace(renamed)

    var archived = try fixture.serverRecord(fixture.workspace.id)
    archived.isArchived = true
    var other = try fixture.serverRecord(fixture.otherWorkspace.id)
    other.name = "Renamed elsewhere"
    fixture.server.commit(workspaces: [archived, other])
    await fixture.deliver()

    #expect(fixture.current?.name == "Renamed here")
    #expect(fixture.current?.isArchived == true)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id)?.name == "Renamed elsewhere")
    #expect(fixture.store.pendingIntents.count == 1)
  }

  @Test("An accepted rename is not clobbered by an earlier delta and retires with the delta that carries it")
  func acceptedRenameRetiresAtItsCursor() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    // Another device changed the workspace first; its event is still on its way.
    var archived = try fixture.serverRecord(fixture.workspace.id)
    archived.isArchived = true
    let earlier = fixture.server.commit(workspaces: [archived])
    var renamed = fixture.workspace
    renamed.name = "Renamed here"
    renamed.hasCustomName = true
    fixture.sync.renameWorkspace(renamed)
    await fixture.flush()

    let entry = try #require(fixture.store.pendingIntents.first)
    guard case let .awaiting(cursor, _) = entry.state else {
      Issue.record("An accepted rename waits for its event, got \(entry.state)")
      return
    }
    #expect(cursor == earlier + 1)

    // The earlier event carries the workspace with its old name.
    await fixture.server.deliverNext(to: fixture.store, machineId: fixture.serverId)
    #expect(fixture.store.eventCursor(for: fixture.serverId) == earlier)
    #expect(fixture.current?.name == "Renamed here")
    #expect(fixture.current?.isArchived == true)
    #expect(fixture.store.pendingIntents.count == 1)

    await fixture.server.deliverNext(to: fixture.store, machineId: fixture.serverId)
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.current?.name == "Renamed here")
    #expect(fixture.current?.hasCustomName == true)
  }

  @Test("A draft becomes the server's workspace, keeping its chat pane and extra tabs, then sends held panes")
  func draftPromotion() async throws {
    let fixture = await WorkspaceSyncFixture(connected: true)
    let sessionId = UUID()
    var draft = fixture.repository.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: sessionId, initialName: "Draft", serverId: fixture.serverId, projectId: fixture.project.id,
        rootDirectory: "/tmp/draft"),
      legacyGroups: nil)
    #expect(draft.isDraft)
    let chatTabId = try #require(draft.tabId(containingChat: sessionId))
    // The user opens a terminal beside the chat before its first message.
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "draft-shell")
    let terminalTab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id)))
    draft.centerTabs.append(terminalTab)
    fixture.repository.save(draft)
    fixture.sync.publishPane(terminal, workspaceId: draft.id)
    await fixture.flush()
    // Held: the server has no workspace to put it in yet.
    #expect(fixture.server.requests.isEmpty)
    #expect(fixture.store.pendingIntents.count == 1)

    // Opening the chat creates the workspace and the chat's pane (keyed by
    // the chat's id) on the server in one step.
    var workspaceRecord = WorkspaceSyncModel.serverWorkspace(from: draft)
    workspaceRecord.name = "Draft"
    var session = serverSession(
      from: ChatSession(id: sessionId, projectId: fixture.project.id, serverId: fixture.serverId))
    session.workspaceId = draft.id.uuidString
    let chatPane = ServerWorkspacePane(
      id: sessionId.uuidString, workspaceId: draft.id.uuidString, providerId: "codevisor", paneType: "chat",
      title: "New Session", resourceKind: "session", resourceId: sessionId.uuidString,
      createdAt: "2026-09-23T00:00:00.000Z")
    fixture.server.commit(sessions: [session], workspaces: [workspaceRecord], panes: [chatPane])
    await fixture.deliver()

    let promoted = try #require(fixture.repository.workspace(id: draft.id))
    #expect(promoted.isServerSynced)
    #expect(fixture.store.layouts.draft(id: draft.id) == nil)
    #expect(promoted.pane(containingChat: sessionId)?.id == sessionId)
    #expect(promoted.tabId(containingChat: sessionId) == chatTabId)
    #expect(promoted.tabId(containingPane: terminal.id) == terminalTab.id)
    #expect(fixture.repository.workspaceId(forSession: sessionId) == draft.id)

    // The held pane goes out now that the workspace exists.
    await fixture.store.executor.idle(machineId: fixture.serverId)
    #expect(fixture.server.requests == ["upsertPane:terminal"])
    await fixture.deliver()
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.server.panes(in: draft.id).count == 2)
    #expect(fixture.repository.workspace(id: draft.id)?.tabId(containingPane: terminal.id) == terminalTab.id)
  }
}
