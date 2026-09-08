import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct WorkspaceSidebarRouteTests {
  @Test(
    "Archiving a hidden routing chat preserves the visible page",
    arguments: [PaneKind.browser, .newTab, .terminal, .plugin, .document]
  )
  func archiveHiddenChatKeepsPage(kind: PaneKind) throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/sidebar-tests"))
    let closing = ChatSession(projectId: project.id, harnessId: "codex", title: "Closing")
    let sibling = ChatSession(projectId: project.id, harnessId: "codex", title: "Sibling")
    let environment = AppEnvironment.preview(
      seedProjects: [project], seedSessions: [closing, sibling]
    )
    let page = PaneDescriptorState(id: UUID(), kind: kind, name: "Page", terminalKey: "page")
    let pageTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [page], selectedPaneId: page.id, isVisible: true))
    )
    let workspace = Workspace(
      name: "Workspace", rootDirectory: "/sidebar-tests", serverId: closing.serverId,
      projectId: project.id,
      centerTabs: [
        WorkspaceTab(root: .leaf(.centerInitial(sessionId: closing.id))),
        WorkspaceTab(root: .leaf(.centerInitial(sessionId: sibling.id))),
        pageTab,
      ],
      selectedCenterTabId: pageTab.id, bottomGroup: PaneGroupState(),
      createdAt: Date(timeIntervalSince1970: 0)
    )
    environment.workspaces.save(workspace)

    environment.archiveSession(closing)

    let updated = try #require(environment.workspaces.workspace(id: workspace.id))
    #expect(updated.selectedCenterTab == pageTab)
    #expect(updated.pane(containingChat: closing.id) == nil)
    #expect(environment.projectList.sessions.first(where: { $0.id == closing.id })?.isArchived == true)
    #expect(
      environment.workspaceSync.routeDisposition(
        sessionId: closing.id, serverId: closing.serverId, preservingSelectedPane: true
      ) == .keep
    )
    #expect(
      environment.workspaceSync.routeDisposition(
        sessionId: closing.id, serverId: closing.serverId
      ) == .selectSession(sibling.id)
    )

    // A workspace archive still dismisses the page, even with a non-chat
    // tab selected. Preserving a page applies only inside a live workspace.
    environment.archiveWorkspace(updated)
    #expect(
      environment.workspaceSync.routeDisposition(
        sessionId: closing.id, serverId: closing.serverId, preservingSelectedPane: true
      ) == .dismiss
    )
  }
}
