import SwiftUI

struct SidebarHistoryToolbarButtons: View {
  @Environment(\.sidebarHistory) private var history

  var body: some View {
    ControlGroup {
      Button(ShortcutCatalog.title(for: .goBack), systemImage: "chevron.backward") { history?.goBack() }
        .disabled(history?.canGoBack != true)
        .help(Self.help(for: .goBack))
      Button(ShortcutCatalog.title(for: .goForward), systemImage: "chevron.forward") { history?.goForward() }
        .disabled(history?.canGoForward != true)
        .help(Self.help(for: .goForward))
    }
    .controlGroupStyle(.navigation)
  }

  private static func help(for id: ShortcutID) -> String {
    "\(ShortcutCatalog.title(for: id)) \(ShortcutCatalog.display(for: id))"
  }
}
