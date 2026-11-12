import CodevisorCore
import SwiftUI

struct RootSidebarActions: Equatable {
  let newChat: @MainActor () -> Void
  let newBot: @MainActor () -> Void
  let editBot: @MainActor (Bot) -> Void

  static func == (lhs: RootSidebarActions, rhs: RootSidebarActions) -> Bool { true }
}

private struct RootSidebarActionsKey: FocusedValueKey {
  typealias Value = RootSidebarActions
}

extension FocusedValues {
  var rootSidebarActions: RootSidebarActions? {
    get { self[RootSidebarActionsKey.self] }
    set { self[RootSidebarActionsKey.self] = newValue }
  }
}
