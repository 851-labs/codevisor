import Foundation
import Testing

@testable import CodevisorCore

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

    func makeSync(layout: [WorkspaceTab]) async -> WorkspaceSyncModel {
      let project = Project(id: projectId, serverId: "local", name: "codevisor")
      let chat = ChatSession(id: sessionId, projectId: projectId, serverId: "local", title: "Closed chat")
      let workspace = Workspace(
        id: workspaceId, name: "octopus", rootDirectory: "/tmp/octopus", serverId: "local",
        projectId: projectId, centerTabs: layout, isServerSynced: true)
      await navigation.install(projects: [project], sessions: [chat], workspaces: [workspace])
      return navigation.workspaceSync
    }

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
    await fixture.closeChatTab()

    #expect(fixture.projectList.sessions.contains { $0.id == fixture.sessionId })
    #expect(fixture.repository.workspaceId(forSession: fixture.sessionId) == fixture.workspaceId)
    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.pane(containingChat: fixture.sessionId) == nil)
    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.hasOpenNonChatContent == true)

    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: fixture.sessionId
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
        anchorSessionId: fixture.sessionId
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
        anchorSessionId: UUID()
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
      sync.routeDisposition(workspaceId: UUID(), anchorSessionId: fixture.sessionId) == .dismiss)
    _ = await fixture.navigation.store.apply(
      .fixture(cursor: 2, deleted: [("workspaces", fixture.workspaceId.uuidString)]), machineId: "local")
    #expect(
      sync.routeDisposition(workspaceId: fixture.workspaceId, anchorSessionId: fixture.sessionId)
        == .dismiss)
  }
}
