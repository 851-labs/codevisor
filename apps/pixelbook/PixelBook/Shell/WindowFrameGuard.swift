import AppKit
import SwiftUI

struct WindowFrameGuard: NSViewRepresentable {
  static let defaultSize = NSSize(width: 1040, height: 720)

  func makeNSView(context: Context) -> NSView {
    GuardView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class GuardView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
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
