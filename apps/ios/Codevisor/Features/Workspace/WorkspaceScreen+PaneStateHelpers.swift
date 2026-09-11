import CodevisorCore
import Foundation
import UIKit
import SwiftUI

/// Pane-state and diagnostics helpers, split from `WorkspaceScreen` so the
/// screen's struct body stays within the size ratchet. The static ones touch
/// no view state; the pane-storage accessors read only internal members.
extension WorkspaceScreen {
  static func applyCompactPaneState(
    _ state: PaneGroupState,
    to workspace: inout Workspace
  ) {
    let oldTabs = workspace.centerTabs
    workspace.centerTabs = state.panes.map { pane in
      if let oldTab = oldTabs.first(where: {
        $0.root.groupId(containingPane: pane.id) != nil
      }),
        let oldGroup = oldTab.root.allGroups.first(where: {
          $0.state.panes.contains { $0.id == pane.id }
        })
      {
        let groupState = PaneGroupState(
          panes: [pane], selectedPaneId: pane.id
        )
        return WorkspaceTab(
          id: oldTab.id,
          customTitle: oldTab.customTitle,
          root: .group(id: oldGroup.id, state: groupState),
          activeLeafId: oldGroup.id
        )
      }
      return WorkspaceTab(
        root: .leaf(
          PaneGroupState(
            panes: [pane], selectedPaneId: pane.id
          )
        )
      )
    }
    if workspace.centerTabs.isEmpty {
      workspace.centerTabs = [WorkspaceTab(root: .leaf(PaneGroupState()))]
    }
    workspace.selectedCenterTabId =
      state.selectedPaneId.flatMap { selectedPaneId in
        workspace.centerTabs.first {
          $0.root.groupId(containingPane: selectedPaneId) != nil
        }?.id
      } ?? workspace.centerTabs[0].id
  }

  static func compactPaneState(from workspace: Workspace) -> PaneGroupState {
    let candidates =
      workspace.centerTabs.flatMap { tab in
        tab.root.allGroups.flatMap(\.state.panes)
      }
    var seen = Set<UUID>()
    let shared = candidates.filter { seen.insert($0.id).inserted }
    let selected = workspace.selectedCenterTab.flatMap { tab in
      tab.root.group(id: tab.activeLeafId)?.selectedPaneId
    }
    return PaneGroupState(
      panes: shared,
      selectedPaneId: shared.contains(where: { $0.id == selected })
        ? selected : shared.first?.id
    )
  }

  static func diagnosticID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
  }
}

// MARK: - Pane storage identity (moved from WorkspaceScreen.swift for the size ratchet)
extension WorkspaceScreen {
  var paneStorageId: UUID? {
    resolvedWorkspace?.id ?? activeSessionId
  }

  var legacyPaneSessionIds: [UUID] {
    let workspaceIds = resolvedWorkspace?.chatSessionIds ?? []
    guard let activeSessionId else { return workspaceIds }
    return [activeSessionId] + workspaceIds.filter { $0 != activeSessionId }
  }
}
