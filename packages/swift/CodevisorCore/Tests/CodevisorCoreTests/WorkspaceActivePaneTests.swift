import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace active pane")
struct WorkspaceActivePaneTests {
  @Test func liveSplitFocusOverridesPersistedFocus() {
    let first = UUID(), second = UUID()
    let tab = splitTab(first: first, second: second)

    #expect(tab.resolvedActiveLeafId(preferred: second) == second)
    #expect(tab.resolvedActiveLeafId(preferred: nil) == first)
  }

  @Test func switchingTabsRejectsFocusFromThePreviousTab() {
    let previous = WorkspaceTab(root: .leaf(PaneGroupState()))
    let first = UUID(), second = UUID()
    var selected = splitTab(first: first, second: second)
    selected.activeLeafId = second

    #expect(selected.resolvedActiveLeafId(preferred: previous.activeLeafId) == second)
  }

  @Test func closingTheFocusedSplitSelectsASurvivingPane() {
    let first = UUID(), second = UUID()
    var tab = splitTab(first: first, second: second)
    tab.activeLeafId = second
    tab.root = .leaf(PaneGroupState(), id: first)

    #expect(tab.resolvedActiveLeafId(preferred: second) == first)
    #expect(tab.resolvedActiveLeafId(preferred: nil) == first)
  }

  @Test func emptyLayoutDoesNotInventAnActivePane() {
    let tab = WorkspaceTab(root: .split(orientation: .horizontal, children: []))
    #expect(tab.resolvedActiveLeafId(preferred: UUID()) == nil)
  }

  private func splitTab(first: UUID, second: UUID) -> WorkspaceTab {
    WorkspaceTab(
      root: .split(
        orientation: .horizontal,
        children: [
          SplitChild(fraction: 0.5, node: .leaf(PaneGroupState(), id: first)),
          SplitChild(fraction: 0.5, node: .leaf(PaneGroupState(), id: second)),
        ]),
      activeLeafId: first)
  }
}
