import Foundation
import Testing
@testable import CodevisorCore

struct WorkspaceClosingTests {
  @Test("Only the main chat's pane, and the tab holding it, count as the main chat")
  func mainChatPane() throws {
    let main = UUID()
    let mainTab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: main)))
    let sideTab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    var workspace = makeWorkspace(tabs: [mainTab, sideTab], selected: mainTab.id)
    let mainPane = try #require(mainTab.root.allGroups.first?.state.panes.first)
    let sidePane = try #require(sideTab.root.allGroups.first?.state.panes.first)
    #expect(!workspace.isMainChatPane(mainPane))

    workspace.mainSessionId = main

    #expect(workspace.isMainChatPane(mainPane))
    #expect(!workspace.isMainChatPane(sidePane))
    #expect(workspace.holdsMainChat(mainTab))
    #expect(!workspace.holdsMainChat(sideTab))
  }

  @Test("Closing an inactive tab preserves the selected tab and split")
  func closingInactiveTabKeepsSelection() {
    let closing = WorkspaceTab(root: .leaf(PaneGroupState()))
    let selected = splitTab()
    var workspace = makeWorkspace(tabs: [closing, selected], selected: selected.id)

    workspace.pruneClosedCenterTab(closing.id)

    #expect(workspace.centerTabs == [selected])
    #expect(workspace.selectedCenterTabId == selected.id)
  }

  @Test("Closing an inactive split preserves the active split")
  func closingInactiveSplitKeepsSelection() {
    var selected = splitTab()
    let closingLeaf = selected.root.allGroups[0].id
    selected.root = selected.root.updatingGroup(id: closingLeaf) { _ in PaneGroupState() }
    var workspace = makeWorkspace(tabs: [selected], selected: selected.id)

    workspace.pruneClosedCenterTab(selected.id)

    #expect(workspace.selectedCenterTabId == selected.id)
    #expect(workspace.selectedCenterTab?.activeLeafId == selected.activeLeafId)
    #expect(workspace.centerTree.allGroups.map(\.id) == [selected.activeLeafId])
  }

  @Test("Closing a split in an inactive tab never selects that tab")
  func closingBackgroundSplitKeepsTab() {
    var background = splitTab()
    background.root = background.root.updatingGroup(id: background.activeLeafId) { _ in
      PaneGroupState()
    }
    let selected = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    var workspace = makeWorkspace(tabs: [background, selected], selected: selected.id)

    workspace.pruneClosedCenterTab(background.id)

    #expect(workspace.selectedCenterTab == selected)
    #expect(workspace.centerTabs[0].root.allGroups.count == 1)
    #expect(workspace.centerTabs[0].activeLeafId == background.root.allGroups[0].id)
  }

  @Test("Closing the selected tab selects the tab above it, else the one below")
  func closingSelectedTabChoosesNeighbor() {
    let before = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    let closing = WorkspaceTab(root: .leaf(PaneGroupState()))
    let after = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    var workspace = makeWorkspace(tabs: [before, closing, after], selected: closing.id)

    workspace.pruneClosedCenterTab(closing.id)

    #expect(workspace.selectedCenterTab == before)

    let first = WorkspaceTab(root: .leaf(PaneGroupState()))
    let next = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    var leading = makeWorkspace(tabs: [first, next], selected: first.id)
    leading.pruneClosedCenterTab(first.id)
    #expect(leading.selectedCenterTab == next)
  }

  @Test("A selected tab closed through sync hands selection to the tab above, not the first")
  func syncClosedSelectedTabChoosesNeighbor() {
    let tabs = (0..<3).map { _ in
      var group = PaneGroupState()
      group.addTerminalPane(sessionId: UUID())
      return WorkspaceTab(root: .leaf(group))
    }
    var workspace = makeWorkspace(tabs: tabs, selected: tabs[2].id)
    let records = tabs[..<2].flatMap { $0.root.allGroups.flatMap(\.state.panes) }.map {
      ServerPaneMapping.record(from: $0, workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 0))
    }

    WorkspacePaneReconciler(records: records, protectedLocalPaneIds: []).reconcile(&workspace)

    #expect(workspace.centerTabs.map(\.id) == [tabs[0].id, tabs[1].id])
    #expect(workspace.selectedCenterTabId == tabs[1].id)
  }

  @Test("A final pane converted to New Tab keeps its tab identity")
  func replacementKeepsTab() {
    var state = PaneGroupState()
    state.addNewTabPane()
    let selected = WorkspaceTab(root: .leaf(state))
    var workspace = makeWorkspace(tabs: [selected], selected: selected.id)

    workspace.pruneClosedCenterTab(selected.id)

    #expect(workspace.centerTabs == [selected])
    #expect(workspace.selectedCenterTabId == selected.id)
  }

  private func splitTab() -> WorkspaceTab {
    let first = UUID()
    let second = UUID()
    let root = SplitNode.group(id: first, state: .centerInitial(sessionId: UUID()))
      .splitting(
        groupId: first, edge: .trailing, newGroupId: second,
        newGroupState: .centerInitial(sessionId: UUID())
      )
    return WorkspaceTab(root: root, activeLeafId: second)
  }

  private func makeWorkspace(tabs: [WorkspaceTab], selected: UUID) -> Workspace {
    Workspace(
      name: "Sidebar tests", rootDirectory: "/sidebar-tests", serverId: "local",
      projectId: UUID(), centerTabs: tabs, selectedCenterTabId: selected, createdAt: Date(timeIntervalSince1970: 0)
    )
  }
}
