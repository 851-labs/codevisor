import AppKit

@MainActor
enum PlayerPresentation {
  static func show(_ window: NSWindow) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate()
    application.presentationOptions = [.hideDock, .hideMenuBar]
    window.makeKeyAndOrderFront(nil)
  }

  static func hide(_ window: NSWindow) {
    window.close()
    NSApplication.shared.presentationOptions = []
  }
}
