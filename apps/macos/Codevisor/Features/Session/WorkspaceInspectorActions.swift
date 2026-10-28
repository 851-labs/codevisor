import SwiftUI

struct WorkspaceInspectorActions: Equatable {
  let isVisible: Bool
  let tabs: [WorkspaceInspectorTab]
  let harnessId: String?
  let toggle: @MainActor () -> Void
  let show: @MainActor (WorkspaceInspectorTab) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    (lhs.isVisible, lhs.tabs, lhs.harnessId) == (rhs.isVisible, rhs.tabs, rhs.harnessId)
  }
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
