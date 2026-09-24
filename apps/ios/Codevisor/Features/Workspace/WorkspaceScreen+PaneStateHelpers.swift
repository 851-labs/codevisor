import CodevisorCore
import Foundation
import UIKit
import SwiftUI

/// Pane-state and diagnostics helpers, split from `WorkspaceScreen` so the
/// screen's struct body stays within the size ratchet. The static ones touch
/// no view state; the pane-storage accessors read only internal members.
/// The projection itself is `PaneLayoutProjection` in CodevisorCore.
extension WorkspaceScreen {
  /// Writes the flat pane state back through the split-preserving
  /// projection, so a layout built on macOS or on the unfolded iPhone Duo
  /// display survives the phone's one-pane edits.
  static func applyCompactPaneState(
    _ state: PaneGroupState,
    to workspace: inout Workspace
  ) {
    PaneLayoutProjection.apply(state, to: &workspace)
  }

  static func compactPaneState(from workspace: Workspace) -> PaneGroupState {
    PaneLayoutProjection.flatten(workspace)
  }

  nonisolated static func diagnosticID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
  }
}

/// Which workspace a screen shows and how many times it has changed: a cheap
/// `onChange` value that moves only when that one workspace does.
struct WorkspaceScreenWorkspaceVersion: Equatable {
  let id: UUID?
  let generation: UInt64
}

// MARK: - Pane storage identity (moved from WorkspaceScreen.swift for the size ratchet)
extension WorkspaceScreen {
  var workspaceVersion: WorkspaceScreenWorkspaceVersion {
    let entry = workspaceEntry
    return WorkspaceScreenWorkspaceVersion(id: entry?.id, generation: entry?.generation ?? 0)
  }

  var paneStorageId: UUID? {
    resolvedWorkspace?.id ?? activeSessionId
  }

  var legacyPaneSessionIds: [UUID] {
    let workspaceIds = resolvedWorkspace?.chatSessionIds ?? []
    guard let activeSessionId else { return workspaceIds }
    return [activeSessionId] + workspaceIds.filter { $0 != activeSessionId }
  }
}
