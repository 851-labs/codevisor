import CodevisorCore
import CodevisorUI
import SwiftUI

/// The unfolded iPhone Duo display renders the selected tab's split tree.
/// Everything here keeps the flat `paneState` as the screen's working set;
/// the tree is read from the repository and written back through the
/// split-preserving projection.
extension WorkspaceScreen {
  /// The tab to render as a split: only on a regular-width layout, and
  /// only when it actually has more than one leaf.
  var splitTab: WorkspaceTab? {
    guard homeLayoutMode == .split, !isDraft,
      let tab = resolvedWorkspace?.selectedCenterTab,
      tab.root.allGroups.count > 1
    else { return nil }
    return tab
  }

  /// Opens a New Tab page beside the active pane, splitting its leaf.
  func openBeside() {
    guard var workspace = resolvedWorkspace else { return }
    if let sourcePane = activePane ?? panes.panes.first {
      chatController(for: sourcePane)?.rememberCurrentComposerConfiguration()
    }
    // Align the tree's selected tab and active leaf with the flat
    // selection before splitting beside it.
    Self.applyCompactPaneState(panes, to: &workspace)
    var seed = PaneGroupState()
    let newPane = seed.addNewTabPane()
    guard PaneLayoutProjection.split(&workspace, edge: .trailing, pane: newPane) != nil else { return }
    environment.workspaces.save(workspace)
    environment.workspaceSync.noteLocalMutation()
    paneState = Self.compactPaneState(from: workspace)
    publishPane(newPane)
    IOSNavigationDiagnostics.record("workspace.openBeside", "pane=\(Self.diagnosticID(newPane.id))")
  }

  /// A divider drag settled: keep the fractions, nothing else.
  func persistSplitTree(_ root: SplitNode) {
    guard var workspace = resolvedWorkspace, let index = workspace.selectedCenterTabIndex else { return }
    workspace.centerTabs[index].root = root.normalized
    environment.workspaces.save(workspace)
    environment.workspaceSync.noteLocalMutation()
  }
}
