import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct WorkspaceSidebarRouteTests {
  @Test(
    "Archiving a hidden routing chat preserves the visible page",
    arguments: [PaneKind.browser, .newTab, .terminal, .plugin, .document]
  )
  func archiveHiddenChatKeepsPage(kind: PaneKind) async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/sidebar-tests"))
    let closing = ChatSession(projectId: project.id, harnessId: "codex", title: "Closing")
    let sibling = ChatSession(projectId: project.id, harnessId: "codex", title: "Sibling")
    let environment = AppEnvironment.preview(
      seedProjects: [project], seedSessions: [closing, sibling]
    )
    // Shaped like the server's copy, so the pane survives a round trip
    // through the shared pane registry.
    let pageId = UUID()
    let page = PaneDescriptorState(
      id: pageId, kind: kind, name: "Page", terminalKey: kind == .terminal ? "page" : pageId.uuidString,
      pluginId: kind == .plugin ? "example" : nil, pluginPaneType: kind == .plugin ? "pane" : nil,
      documentPath: kind == .document ? "/sidebar-tests/README.md" : nil)
    let pageTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [page], selectedPaneId: page.id))
    )
    let workspace = Workspace(
      name: "Workspace", rootDirectory: "/sidebar-tests", serverId: closing.serverId,
      projectId: project.id,
      centerTabs: [
        WorkspaceTab(root: .leaf(.centerInitial(sessionId: closing.id))),
        WorkspaceTab(root: .leaf(.centerInitial(sessionId: sibling.id))),
        pageTab,
      ],
      selectedCenterTabId: pageTab.id,
      createdAt: Date(timeIntervalSince1970: 0),
      isServerSynced: true
    )
    // The server has the workspace; this device's tab arrangement is local.
    environment.navigationStore.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    await environment.navigationStore.replace(
      .fixture(projects: [project], sessions: [closing, sibling], workspaces: [workspace]),
      machineId: closing.serverId, requestedAt: Date())

    environment.closeSession(closing)

    let updated = try #require(environment.workspaces.workspace(id: workspace.id))
    #expect(updated.selectedCenterTabId == pageTab.id)
    #expect(updated.selectedCenterTab?.root.allGroups.first?.state.selectedPane?.id == page.id)
    #expect(updated.pane(containingChat: closing.id) == nil)
    // Closing removes the pane; the chat row itself is untouched.
    #expect(environment.projectList.sessions.contains { $0.id == closing.id })
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
