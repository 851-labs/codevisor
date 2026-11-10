import CodevisorCore
import SwiftUI

struct KeyboardNavigationPrompt: ViewModifier {
  @ClientPreference("keyboardNavigation.promptDeclined", default: false) private var isDeclined
  @State private var setting = KeyboardNavigationSetting()
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .background(
        KeyboardNavigationTabWatcher(isActive: canPrompt) { isPresented = true }
          .frame(width: 0, height: 0)
      )
      .sheet(isPresented: $isPresented) {
        KeyboardNavigationSheet(setting: setting) { isDeclined = true }
      }
  }

  private var canPrompt: Bool {
    !isDeclined && !setting.isEnabled
  }
}
