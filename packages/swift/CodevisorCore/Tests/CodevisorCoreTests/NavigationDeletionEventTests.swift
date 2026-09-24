import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Deletions arrive as `navigation.changed` deltas and move the cache
/// forward; nothing older -- a snapshot fetched before them -- can bring the
/// deleted records back.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationDeletionEventTests {
  /// The deletions the server's journal records for `kind`, cascades included.
  private func deletions(
    _ kind: String, fixture: WorkspaceSyncFixture, extra: [Workspace]
  ) -> [(table: String, id: String)] {
    switch kind {
    case "project.deleted":
      let workspaces = ([fixture.workspace, fixture.otherWorkspace] + extra).filter {
        $0.projectId == fixture.project.id
      }
      return [("projects", fixture.project.id.uuidString), ("sessions", fixture.anchorSessionId.uuidString)]
        + workspaces.map { ("workspaces", $0.id.uuidString) }
        + [("workspace_panes", fixture.anchorSessionId.uuidString)]
    default:
      return [
        ("workspaces", fixture.workspace.id.uuidString),
        ("workspace_panes", fixture.anchorSessionId.uuidString),
      ]
    }
  }

  @Test(
    "Workspace and project deletions cannot be resurrected by an older snapshot",
    arguments: ["workspace.deleted", "project.deleted"])
  func deletionSupersedesWorkspaceSnapshot(kind: String) async throws {
    let fixture = await WorkspaceSyncFixture()
    let unrelatedWorkspace = Workspace(
      name: "Unrelated project", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTabs: [.placeholder()], createdAt: fixture.workspace.createdAt, isServerSynced: true)
    var record = WorkspaceSyncModel.serverWorkspace(from: unrelatedWorkspace)
    record.name = "Unrelated project"
    fixture.server.commit(workspaces: [record])
    await fixture.deliver()
    let stale = fixture.server.current
    let fetchedAt = Date()

    fixture.server.commit(deleted: deletions(kind, fixture: fixture, extra: [unrelatedWorkspace]))
    await fixture.deliver()
    await fixture.store.replace(stale, machineId: fixture.serverId, requestedAt: fetchedAt, resetsStream: false)

    #expect(fixture.repository.workspace(id: fixture.workspace.id) == nil)
    if kind == "project.deleted" {
      #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == nil)
      #expect(fixture.projectList.sessions.isEmpty)
      #expect(fixture.projectList.projects.isEmpty)
    } else {
      #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) != nil)
      // The chat outlives its workspace; its route no longer has anywhere to go.
      #expect(fixture.projectList.sessions.map(\.id) == [fixture.anchorSessionId])
      #expect(fixture.sync.routeDisposition(sessionId: fixture.anchorSessionId, serverId: "local") == .dismiss)
    }
    #expect(fixture.repository.workspace(id: unrelatedWorkspace.id)?.name == "Unrelated project")
  }

  @Test(
    "Session deletion removes the chat's pane and its route without a refresh",
    arguments: [PaneKind.chat, .browser, .terminal])
  func sessionDeletionPrunesPanes(selectedKind: PaneKind) async throws {
    let page = PaneDescriptorState(id: UUID(), kind: selectedKind, name: "Page", terminalKey: "page")
    let fixture = await WorkspaceSyncFixture { workspace, _ in
      guard selectedKind != .chat else { return }
      let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [page], selectedPaneId: page.id)))
      workspace.centerTabs.append(tab)
      workspace.selectedCenterTabId = tab.id
    }
    #expect(fixture.sync.routeDisposition(sessionId: fixture.anchorSessionId, serverId: "local") == .keep)

    fixture.server.commit(deleted: [
      ("sessions", fixture.anchorSessionId.uuidString),
      ("workspace_panes", fixture.anchorSessionId.uuidString),
    ])
    await fixture.deliver()

    let updated = try #require(fixture.current)
    #expect(updated.pane(containingChat: fixture.anchorSessionId) == nil)
    #expect(!updated.centerTabs.isEmpty)
    if selectedKind != .chat {
      #expect(updated.tabId(containingPane: page.id) != nil)
    }
    #expect(fixture.projectList.sessions.isEmpty)
    #expect(fixture.sync.routeDisposition(sessionId: fixture.anchorSessionId, serverId: "local") == .dismiss)
    #expect(
      fixture.sync.routeDisposition(
        workspaceId: fixture.workspace.id, anchorSessionId: fixture.anchorSessionId, serverId: "local",
        preservingSelectedPane: true) == .dismiss)
  }

  @Test(
    "Live session changes and deletions supersede a snapshot that was already in flight",
    arguments: ["session.updated", "session.deleted", "project.deleted"])
  func liveEventSupersedesInFlightSnapshot(kind: String) async throws {
    let fixture = await WorkspaceSyncFixture()
    let started = TestSignal()
    let release = TestSignal()
    fixture.server.onSnapshot {
      started.signal()
      await release.wait()
    }
    let refresh = Task {
      await fixture.projectList.refreshFromServer(serverId: fixture.serverId, client: fixture.server)
    }
    defer {
      release.signal()
      refresh.cancel()
    }
    await started.wait()

    switch kind {
    case "session.updated":
      var session = serverSession(
        from: ChatSession(
          id: fixture.anchorSessionId, projectId: fixture.project.id, serverId: "local", title: "Renamed remotely",
          createdAt: fixture.workspace.createdAt))
      session.workspaceId = fixture.workspace.id.uuidString
      fixture.server.commit(sessions: [session])
    case "session.deleted":
      fixture.server.commit(deleted: [
        ("sessions", fixture.anchorSessionId.uuidString),
        ("workspace_panes", fixture.anchorSessionId.uuidString),
      ])
    default:
      fixture.server.commit(deleted: deletions(kind, fixture: fixture, extra: []))
    }
    await fixture.deliver()
    release.signal()
    _ = await refresh.value

    if kind == "session.updated" {
      #expect(fixture.projectList.sessions.first?.title == "Renamed remotely")
    } else {
      #expect(fixture.projectList.sessions.isEmpty)
    }
    #expect(fixture.store.eventCursor(for: fixture.serverId) == 2)
  }
}
