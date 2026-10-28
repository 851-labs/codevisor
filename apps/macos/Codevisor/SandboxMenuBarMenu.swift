import AppKit
import SwiftUI

struct SandboxMenuBarMenu: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Open Codevisor", action: showMainWindow)
    Button("Settings…", action: showSettings)
    Divider()
    Button("Quit Codevisor") { NSApp.terminate(nil) }
  }

  private func showMainWindow() {
    NSApp.activate()
    if let window = Self.openMainWindow() {
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: MainWindowScene.id)
    }
  }

  private func showSettings() {
    NSApp.activate()
    openSettings()
  }

  private static func openMainWindow() -> NSWindow? {
    NSApp.windows.first { window in
      window.isVisible && window.identifier?.rawValue.hasPrefix(MainWindowScene.id) == true
    }
  }
}
