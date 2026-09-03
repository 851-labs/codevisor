import AppKit
import SwiftUI

/// On macOS 27 betas a freshly created `NavigationSplitView` window ignores
/// `defaultSize` and opens at SwiftUI's 100 000pt width cap (the detail
/// column reports an unbounded ideal width). Windows restored from saved
/// state are unaffected. This probe clamps such a window to the intended
/// default size the first time it lands on screen.
struct WindowFrameGuard: NSViewRepresentable {
  static let defaultSize = NSSize(width: 1040, height: 720)

  func makeNSView(context: Context) -> NSView {
    GuardView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class GuardView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // Resizing from inside the display cycle raises; do it on the next
      // turn of the run loop.
      DispatchQueue.main.async { [weak self] in self?.clampIfNeeded() }
    }

    private func clampIfNeeded() {
      guard let window, window.frame.width > 4000 else { return }
      let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      var frame = window.frame
      frame.size = WindowFrameGuard.defaultSize
      frame.origin.x = screen.midX - frame.width / 2
      frame.origin.y = screen.midY - frame.height / 2
      window.setFrame(frame, display: true)
    }
  }
}
