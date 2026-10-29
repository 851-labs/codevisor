import AppKit

@MainActor
enum BenchPresentation {
  private static var activationObserver: (any NSObjectProtocol)?

  static func hideMenuBarOnceActive() {
    let application = NSApplication.shared
    guard !application.isActive else { return hideMenuBar() }

    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: application, queue: .main
    ) { _ in
      MainActor.assumeIsolated { hideMenuBar() }
    }
  }

  static func restoreMenuBar() {
    activationObserver.map(NotificationCenter.default.removeObserver)
    activationObserver = nil
    guard NSApplication.shared.isActive else { return }

    NSApplication.shared.presentationOptions = []
  }

  private static func hideMenuBar() {
    NSApplication.shared.presentationOptions = [.hideDock, .hideMenuBar]
  }
}
