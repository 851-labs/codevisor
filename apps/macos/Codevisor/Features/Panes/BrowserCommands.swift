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
    CommandGroup(after: .toolbar) {
      Button("Open Location") { page?.focusAddress() }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(page == nil)
      Button("Developer Tools") { page?.showDevTools() }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(page == nil)
      Button("Reload Page") { page?.reload() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(page == nil)
      Divider()
      ShortcutButton(.browserZoomIn) { page?.zoom(.zoomIn) }
        .disabled(page?.canZoomIn != true)
      ShortcutButton(.browserZoomOut) { page?.zoom(.zoomOut) }
        .disabled(page?.canZoomOut != true)
      ShortcutButton(.browserResetZoom) { page?.zoom(.reset) }
        .disabled(page?.canResetZoom != true)
    }
  }
}
