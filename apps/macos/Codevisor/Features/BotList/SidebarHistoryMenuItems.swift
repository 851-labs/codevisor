import SwiftUI

struct SidebarHistoryMenuItems: View {
  @FocusedValue(\.sidebarHistory) private var history

  var body: some View {
    ShortcutButton(.goBack) { history?.goBack() }
      .disabled(history?.canGoBack != true)
    ShortcutButton(.goForward) { history?.goForward() }
      .disabled(history?.canGoForward != true)
    Divider()
  }
}
