import Foundation
import Testing

@testable import CodevisorCore

/// The New Tab page is device-local: never published, never listed by the
/// server. A workspace showing only that page holds it as a placeholder that
/// the first real pane fills in place — it must never linger beside real
/// panes as a phantom row on a client that watched another client create a
/// chat.
@MainActor
@Suite("WorkspaceSyncModel placeholder tab")
struct WorkspaceSyncPlaceholderTabTests {
  private let serverId = "remote-mac"
  private let projectId = UUID()

  private func chatRecord(workspaceId: UUID, sessionId: UUID) -> ServerWorkspacePane {
    ServerWorkspacePane(
      id: sessionId.uuidString.lowercased(),
      workspaceId: workspaceId.uuidString.lowercased(), providerId: "codevisor",
      paneType: "chat", title: "Hello", resourceKind: "session",
      resourceId: sessionId.uuidString.lowercased(), createdAt: "2026-09-17T00:00:00.000Z"
    )
  }

  private func legacyNewTabRecord(workspaceId: UUID) -> ServerWorkspacePane {
    ServerWorkspacePane(
      id: UUID().uuidString.lowercased(),
      workspaceId: workspaceId.uuidString.lowercased(), providerId: "codevisor",
      paneType: "new-tab", title: "New tab", createdAt: "2026-09-17T00:00:00.000Z"
    )
  }

  private func placeholderWorkspace(tabs: [WorkspaceTab] = [.placeholder()]) -> Workspace {
    Workspace(
      name: "Shared", rootDirectory: "/tmp/shared", serverId: serverId, projectId: projectId,
      centerTabs: tabs,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), isServerSynced: true
    )
  }

  @Test("The first remote pane fills the placeholder tab in place")
  func firstPaneFillsPlaceholder() throws {
    var workspace = placeholderWorkspace()
    let placeholder = try #require(workspace.centerTabs.first)
    let sessionId = UUID()

    WorkspaceSyncModel.reconcilePanes(
      in: &workspace, records: [chatRecord(workspaceId: workspace.id, sessionId: sessionId)],
      protectedLocalPaneIds: [])

    #expect(workspace.centerTabs.map(\.id) == [placeholder.id])
    #expect(workspace.selectedCenterTabId == placeholder.id)
    let tab = try #require(workspace.centerTabs.first)
    #expect(tab.activeLeafId == placeholder.activeLeafId)
    let group = try #require(tab.root.group(id: placeholder.activeLeafId))
    #expect(group.panes.map(\.chatSessionId) == [sessionId])
    #expect(group.selectedPaneId == group.panes.first?.id)
    #expect(!workspace.centerTabs.contains(where: { $0.isPlaceholder }))
  }

  @Test("Extra placeholders go with the first real pane; a New Tab beside real panes stays")
  func placeholdersRetireOnlyWhileNothingElseExists() throws {
    let sessionId = UUID()
    var filling = placeholderWorkspace(tabs: [.placeholder(), .placeholder()])
    WorkspaceSyncModel.reconcilePanes(
      in: &filling, records: [chatRecord(workspaceId: filling.id, sessionId: sessionId)],
      protectedLocalPaneIds: [])
    #expect(filling.centerTabs.count == 1)
    #expect(filling.chatSessionIds == [sessionId])

    // ⌘T beside a chat: the page is this device's, the server never lists
    // it, and the snapshot must not take it away.
    let chatTab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId, paneId: sessionId)))
    var chromeLike = placeholderWorkspace(tabs: [chatTab, .placeholder()])
    WorkspaceSyncModel.reconcilePanes(
      in: &chromeLike, records: [chatRecord(workspaceId: chromeLike.id, sessionId: sessionId)],
      protectedLocalPaneIds: [])
    #expect(chromeLike.centerTabs.map(\.id) == [chatTab.id, chromeLike.centerTabs[1].id])
    #expect(chromeLike.centerTabs[1].isPlaceholder)
  }

  @Test("A workspace with no real panes keeps its placeholder identity across snapshots")
  func placeholderIdentityIsStable() throws {
    var workspace = placeholderWorkspace()
    let before = workspace

    WorkspaceSyncModel.reconcilePanes(in: &workspace, records: [], protectedLocalPaneIds: [])
    #expect(workspace == before)

    // A row from a client that still publishes its New Tab page is ignored.
    WorkspaceSyncModel.reconcilePanes(
      in: &workspace, records: [legacyNewTabRecord(workspaceId: workspace.id)],
      protectedLocalPaneIds: [])
    #expect(workspace == before)
  }

  @Test("Closing the last pane elsewhere leaves this device on a stable New Tab page")
  func remoteCloseOfLastPaneLeavesPlaceholder() throws {
    let sessionId = UUID()
    var workspace = placeholderWorkspace(tabs: [
      WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId, paneId: sessionId)))
    ])

    WorkspaceSyncModel.reconcilePanes(in: &workspace, records: [], protectedLocalPaneIds: [])
    #expect(workspace.centerTabs.count == 1)
    let placeholder = try #require(workspace.centerTabs.first)
    #expect(placeholder.isPlaceholder)
    #expect(workspace.selectedCenterTabId == placeholder.id)

    WorkspaceSyncModel.reconcilePanes(in: &workspace, records: [], protectedLocalPaneIds: [])
    #expect(workspace.centerTabs.map(\.id) == [placeholder.id])
  }

  @Test("Observing a workspace record before its first pane yields one tab")
  func workspaceRecordBeforePaneYieldsSingleTab() throws {
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let sync = WorkspaceSyncModel(repository: repository, projectList: projectList)
    let record = WorkspaceSyncModel.serverWorkspace(from: placeholderWorkspace())
    let workspaceId = try #require(UUID(uuidString: record.id))
    let sessionId = UUID()
    func snapshot(panes: [ServerWorkspacePane]) -> ServerNavigationSnapshot {
      ServerNavigationSnapshot(
        eventCursor: 0, projects: [], sessions: [], workspaces: [record], panes: panes)
    }

    // The other client's workspace row lands first...
    sync.applyNavigationSnapshot(snapshot(panes: []), serverId: serverId)
    let paneLess = try #require(repository.workspace(id: workspaceId))
    #expect(paneLess.centerTabs.count == 1)
    #expect(!paneLess.hasRealPanes)

    // ...then its chat pane.
    sync.applyNavigationSnapshot(
      snapshot(panes: [chatRecord(workspaceId: workspaceId, sessionId: sessionId)]), serverId: serverId)
    let synced = try #require(repository.workspace(id: workspaceId))
    #expect(synced.centerTabs.map(\.id) == paneLess.centerTabs.map(\.id))
    #expect(synced.chatSessionIds == [sessionId])
    #expect(!synced.centerTabs.contains(where: { $0.isPlaceholder }))
    #expect(synced.selectedCenterTabId == synced.centerTabs.first?.id)

    // A later snapshot with the same pane is a no-op.
    sync.applyNavigationSnapshot(
      snapshot(panes: [chatRecord(workspaceId: workspaceId, sessionId: sessionId)]), serverId: serverId)
    #expect(repository.workspace(id: workspaceId) == synced)
  }
}
