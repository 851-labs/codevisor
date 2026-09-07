import AppKit
import SwiftUI

/// A SwiftUI tap gesture on the browser's ancestor cancels AppKit's button
/// tracking when the mouse is released. Observe clicks without recognizing or
/// consuming them so the browser's native controls receive the entire click.
struct BrowserPaneActivationObserver: NSViewRepresentable {
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

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
