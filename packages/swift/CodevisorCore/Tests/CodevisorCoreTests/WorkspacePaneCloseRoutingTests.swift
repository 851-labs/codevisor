import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Workspace pane close routing")
struct WorkspacePaneCloseRoutingTests {
  @Test(
    "Archiving a split chat preserves the remaining pane and selected tab",
    arguments: [PaneKind.browser, .terminal, .plugin, .document, .newTab, .chat], [false, true]
  )
  func archiveSplitChat(remainingKind: PaneKind, hasOtherTab: Bool) throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/workspace"), createdAt: date)
    let closing = ChatSession(projectId: project.id, harnessId: "codex", title: "Closing", createdAt: date)
    let other = ChatSession(projectId: project.id, harnessId: "codex", title: "Other tab", createdAt: date)
    let remainingChat = ChatSession(projectId: project.id, harnessId: "codex", title: "Split chat", createdAt: date)
    let environment = AppEnvironment.preview(
      seedProjects: [project],
      seedSessions: [closing] + (hasOtherTab ? [other] : []) + (remainingKind == .chat ? [remainingChat] : []))
    let remaining = PaneDescriptorState(
      id: UUID(), kind: remainingKind, name: "Remaining pane", terminalKey: "remaining",
      chatSessionId: remainingKind == .chat ? remainingChat.id : nil,
      browserURL: remainingKind == .browser ? "https://example.com/" : nil)
    let remainingLeaf = UUID(), closingLeaf = UUID()
    let root = SplitNode.leaf(
      PaneGroupState(panes: [remaining], selectedPaneId: remaining.id), id: remainingLeaf
    ).splitting(
      groupId: remainingLeaf, edge: .trailing, newGroupId: closingLeaf,
      newGroupState: .centerInitial(sessionId: closing.id))
    let selected = WorkspaceTab(root: root, activeLeafId: closingLeaf)
    let otherTab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: other.id)))
    let workspace = Workspace(
      name: "Workspace", rootDirectory: "/fixture/workspace", serverId: closing.serverId, projectId: project.id,
      centerTabs: (hasOtherTab ? [otherTab] : []) + [selected], selectedCenterTabId: selected.id, createdAt: date)
    environment.workspaces.save(workspace)

    environment.archiveSession(closing)

    let after = try #require(environment.workspaces.workspace(id: workspace.id))
    #expect(environment.projectList.sessions.first(where: { $0.id == closing.id })?.isArchived == true)
    #expect(after.selectedCenterTabId == selected.id)
    #expect(after.selectedCenterTab?.activeLeafId == remainingLeaf)
    #expect(after.selectedCenterTab?.root.allGroups.map(\.id) == [remainingLeaf])
    #expect(after.selectedPane(inLeaf: remainingLeaf) == remaining)
    #expect(after.pane(containingChat: closing.id) == nil)
    if hasOtherTab { #expect(after.centerTabs.first == otherTab) }
    #expect(
      environment.workspaceSync.routeDisposition(
        sessionId: closing.id, serverId: closing.serverId, preservingSelectedPane: true
      ) == .keep)
    if remainingKind == .newTab && !hasOtherTab {
      #expect(environment.workspaceSync.routeDisposition(sessionId: closing.id, serverId: closing.serverId) == .dismiss)
    }
  }
}
