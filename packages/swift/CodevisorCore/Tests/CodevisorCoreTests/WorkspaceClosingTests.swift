import Foundation
import Testing
@testable import CodevisorCore

struct WorkspaceClosingTests {
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

  @Test("Closing the selected tab selects its next neighbor")
  func closingSelectedTabChoosesNeighbor() {
    let before = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    let closing = WorkspaceTab(root: .leaf(PaneGroupState()))
    let after = WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))
    var workspace = makeWorkspace(tabs: [before, closing, after], selected: closing.id)

    workspace.pruneClosedCenterTab(closing.id)

    #expect(workspace.selectedCenterTab == after)
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
