import CodevisorCore
import SwiftUI

/// The menu bar's tab actions for this workspace.
extension WorkspaceScreen {
  var commandActions: WorkspaceCommandActions? {
    guard !isDraft, !blocksServerContent, paneState != nil else { return nil }
    return WorkspaceCommandActions(
      workspaceId: resolvedWorkspace?.id,
      paneCount: panes.panes.count,
      newTab: { addTab() },
      closeTab: {
        if let pane = activePane { close(pane) }
      },
      selectTab: { offset in selectTab(offset: offset) }
    )
  }

  /// Steps through the tabs in sidebar order, wrapping at either end.
  func selectTab(offset: Int) {
    guard let current = activePane, let target = panes.pane(steppingFrom: current.id, by: offset) else { return }
    select(target)
  }
}
