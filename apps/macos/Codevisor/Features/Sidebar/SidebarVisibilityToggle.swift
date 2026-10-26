import SwiftUI

struct SidebarVisibilityToggle: Equatable {
  let isVisible: Bool
  let setVisible: @MainActor (Bool) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.isVisible == rhs.isVisible }
}

private struct SidebarVisibilityToggleKey: FocusedValueKey {
  typealias Value = SidebarVisibilityToggle
}

extension FocusedValues {
  var sidebarVisibility: SidebarVisibilityToggle? {
    get { self[SidebarVisibilityToggleKey.self] }
    set { self[SidebarVisibilityToggleKey.self] = newValue }
  }
}
