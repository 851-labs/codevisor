import SwiftUI

private struct SettingsAddToolbarItem<Action: View>: ViewModifier {
  let action: Action

  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .primaryAction) {
        action
          .labelStyle(.iconOnly)
          .menuIndicator(.hidden)
      }
    }
  }
}

extension View {
  func settingsAddToolbarItem<Action: View>(@ViewBuilder _ action: () -> Action) -> some View {
    modifier(SettingsAddToolbarItem(action: action()))
  }
}
