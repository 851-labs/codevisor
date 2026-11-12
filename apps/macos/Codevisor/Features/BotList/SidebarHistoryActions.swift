import SwiftUI

struct SidebarHistoryActions: Equatable {
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: @MainActor () -> Void
  let goForward: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canGoBack == rhs.canGoBack && lhs.canGoForward == rhs.canGoForward
  }
}

private struct SidebarHistoryActionsKey: FocusedValueKey {
  typealias Value = SidebarHistoryActions
}

extension FocusedValues {
  var sidebarHistory: SidebarHistoryActions? {
    get { self[SidebarHistoryActionsKey.self] }
    set { self[SidebarHistoryActionsKey.self] = newValue }
  }
}
