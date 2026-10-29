import AppKit
import ScreenSharing

@MainActor
final class OnscreenViewer: LoopbackViewer {
  private let window: NSWindow
  private let view: ScreenSharingMetalView

  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
    guard let screen = NSScreen.main else { throw BenchUsageError(message: "--onscreen needs a display") }

    view = try ScreenSharingMetalView(
      mailbox: mailbox, metrics: metrics, renderOnArrival: true, offMainPreparation: true)
    window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.level = .mainMenu
    window.backgroundColor = .black
    window.contentView = view
    window.setFrame(screen.frame, display: true)
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func stop() {
    view.stop()
    window.close()
  }
}
