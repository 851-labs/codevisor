import AppKit
import SwiftUI

/// Makes a click anywhere in a pane activate it, so keyboard shortcuts follow
/// the pane you're working in. Observes clicks without recognizing or consuming
/// them: AppKit views that take the mouse-down (the composer's text view, a
/// simulator's screen) keep a SwiftUI tap gesture from ever firing, and on the
/// browser such a gesture cancels AppKit's button tracking on mouse-up.
struct PaneActivationObserver: NSViewRepresentable {
  let onActivate: () -> Void

  func makeNSView(context: Context) -> ClickObserverView {
    let view = ClickObserverView()
    view.onActivate = onActivate
    return view
  }

  func updateNSView(_ view: ClickObserverView, context: Context) {
    view.onActivate = onActivate
  }

  final class ClickObserverView: NSView {
    var onActivate: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        else { return event }
        self.onActivate?()
        return event
      }
    }

    isolated deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
