import AppKit

@MainActor
enum PlayerPresentation {
  static func show(_ window: NSWindow) {
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    BenchPresentation.hideMenuBarOnceActive()
  }

  static func hide(_ window: NSWindow) {
    window.close()
    BenchPresentation.restoreMenuBar()
  }
}
