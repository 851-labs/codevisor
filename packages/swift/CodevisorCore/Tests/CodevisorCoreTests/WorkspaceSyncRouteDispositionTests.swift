import Foundation
import Testing

@testable import CodevisorCore

/// The keep/sibling/dismiss policy for a workspace whose chats are all
/// CLOSED — they still belong to it, but none of them has a pane. The
/// sidebar lists such a workspace by its terminal/plugin tabs, and a session
/// route is the only way to mount it, so the closed chat still assigned to it
/// must keep the route — unless nothing but the New Tab placeholder is left.
@MainActor
struct WorkspaceSyncRouteDispositionTests {
  @MainActor
  private struct Fixture {
    let projectId = UUID()
    let sessionId = UUID()
    let workspaceId = UUID()
    let navigation = NavigationFixture()
    var repository: ProjectedWorkspaceRepository { navigation.workspaces }
    var projectList: ProjectListModel { navigation.projectList }

    /// Installs the machine's snapshot: the workspace's panes are the
    /// layout's panes, and a chat in `chatTab` is assigned to it.
    func makeSync(layout: [WorkspaceTab]) async -> WorkspaceSyncModel {
      let project = Project(id: projectId, serverId: "local", name: "codevisor")
      let chat = ChatSession(id: sessionId, projectId: projectId, serverId: "local", title: "Closed chat")
      let workspace = Workspace(
        id: workspaceId, name: "octopus", rootDirectory: "/tmp/octopus", serverId: "local",
        projectId: projectId, centerTabs: layout, isServerSynced: true)
      await navigation.install(projects: [project], sessions: [chat], workspaces: [workspace])
      return navigation.workspaceSync
    }

    /// The chat tab, exactly as an open chat's pane.
    var chatTab: WorkspaceTab {
      let chat = PaneDescriptorState(
        id: sessionId,
        kind: .chat,
        name: "Closed chat",
        terminalKey: sessionId.uuidString,
        chatSessionId: sessionId
      )
      return WorkspaceTab(
        root: .leaf(PaneGroupState(panes: [chat], selectedPaneId: chat.id))
      )
    }

    /// Closing a chat closes its pane on the server. The chat keeps its
    /// workspace assignment -- which is what "closed" means, and what the
    /// route still anchors on.
    func closeChatTab() async {
      _ = await navigation.store.apply(
        .fixture(cursor: 2, deleted: [("workspace_panes", sessionId.uuidString)]), machineId: "local")
    }
  }

  @Test("A chat-less workspace with a live terminal keeps its closed anchor route")
  func terminalKeepsClosedAnchorRoute() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))
    )
    let sync = await fixture.makeSync(layout: [terminalTab, fixture.chatTab])
    // Closing the chat's pane is the whole of "this chat is closed": the chat
    // row and its workspace membership are untouched.
    await fixture.closeChatTab()

    #expect(fixture.projectList.sessions.contains { $0.id == fixture.sessionId })
    #expect(fixture.repository.workspaceId(forSession: fixture.sessionId) == fixture.workspaceId)
    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.pane(containingChat: fixture.sessionId) == nil)
    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.hasOpenNonChatContent == true)

    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: fixture.sessionId,
        serverId: "local"
      ) == .keep
    )
    #expect(sync.routeDisposition(sessionId: fixture.sessionId, serverId: "local") == .keep)
  }

  @Test("A workspace left with only the New Tab placeholder dismisses its closed anchor")
  func placeholderOnlyDismissesClosedAnchor() async throws {
    let fixture = Fixture()
    let placeholderId = UUID()
    let placeholder = PaneDescriptorState(
      id: placeholderId, kind: .newTab, name: "New tab", terminalKey: placeholderId.uuidString
    )
    let placeholderTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [placeholder], selectedPaneId: placeholderId))
    )
    let sync = await fixture.makeSync(layout: [placeholderTab, fixture.chatTab])
    await fixture.closeChatTab()

    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.hasOpenNonChatContent == false)
    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: fixture.sessionId,
        serverId: "local"
      ) == .dismiss
    )
    #expect(sync.routeDisposition(sessionId: fixture.sessionId, serverId: "local") == .dismiss)
  }

  @Test("A closed chat that is not assigned to the workspace does not keep it")
  func unroutedAnchorDismisses() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))
    )
    let sync = await fixture.makeSync(layout: [terminalTab])

    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: UUID(),
        serverId: "local"
      ) == .dismiss
    )
  }

  @Test("A missing workspace or chat dismisses the route")
  func missingWorkspaceOrChatDismisses() async throws {
    let fixture = Fixture()
    let sync = await fixture.makeSync(layout: [fixture.chatTab])
    #expect(sync.routeDisposition(sessionId: fixture.sessionId, serverId: "local") == .keep)
    #expect(sync.routeDisposition(sessionId: UUID(), serverId: "local") == .dismiss)
    #expect(
      sync.routeDisposition(workspaceId: UUID(), anchorSessionId: fixture.sessionId, serverId: "local") == .dismiss)
    _ = await fixture.navigation.store.apply(
      .fixture(cursor: 2, deleted: [("workspaces", fixture.workspaceId.uuidString)]), machineId: "local")
    #expect(
      sync.routeDisposition(workspaceId: fixture.workspaceId, anchorSessionId: fixture.sessionId, serverId: "local")
        == .dismiss)
  }
}
