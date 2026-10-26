import SwiftUI

struct WorkspaceInspectorActions: Equatable {
  let isVisible: Bool
  let toggle: @MainActor () -> Void
  let show: @MainActor (WorkspaceInspectorTab) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.isVisible == rhs.isVisible }
}

private struct WorkspaceInspectorActionsKey: FocusedValueKey {
  typealias Value = WorkspaceInspectorActions
}

extension FocusedValues {
  var workspaceInspector: WorkspaceInspectorActions? {
    get { self[WorkspaceInspectorActionsKey.self] }
    set { self[WorkspaceInspectorActionsKey.self] = newValue }
  }
}
