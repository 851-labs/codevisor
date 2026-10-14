import CodevisorUI
import SwiftUI

private struct BrowserPageKey: FocusedValueKey {
  typealias Value = ChromiumBrowserModel
}

extension FocusedValues {
  var browserPage: ChromiumBrowserModel? {
    get { self[BrowserPageKey.self] }
    set { self[BrowserPageKey.self] = newValue }
  }
}

struct BrowserCommands: Commands {
  @FocusedValue(\.browserPage) private var page

  var body: some Commands {
    if let page {
      CommandMenu("Browser") {
        Button("Open Location") { page.focusAddress() }
          .keyboardShortcut("l", modifiers: .command)
        Button("Developer Tools") { page.showDevTools() }
          .keyboardShortcut("i", modifiers: [.command, .option])
        Button("Reload Page") { page.reload() }
          .keyboardShortcut("r", modifiers: .command)
        Button("Reload Page Ignoring Cache") { page.reload(ignoringCache: true) }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        Divider()
        ShortcutButton(.browserZoomIn) { page.zoom(.zoomIn) }
          .disabled(!page.canZoomIn)
        ShortcutButton(.browserZoomOut) { page.zoom(.zoomOut) }
          .disabled(!page.canZoomOut)
        ShortcutButton(.browserResetZoom) { page.zoom(.reset) }
          .disabled(!page.canResetZoom)
      }
    }
  }
}
