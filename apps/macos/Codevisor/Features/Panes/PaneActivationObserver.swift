import AppKit
import SwiftUI

struct PaneActivationObserver: NSViewRepresentable {
  let onActivate: () -> Void
  var isFloating = false

  func makeNSView(context: Context) -> ClickObserverView {
    let view = ClickObserverView()
    view.onActivate = onActivate
    view.isFloating = isFloating
    return view
  }

  func updateNSView(_ view: ClickObserverView, context: Context) {
    view.onActivate = onActivate
    view.isFloating = isFloating
  }

  final class ClickObserverView: NSView {
    private static let floatingViews = NSHashTable<ClickObserverView>.weakObjects()

    static func isInFloatingPane(_ responder: NSResponder?) -> Bool {
      guard let view = responder as? NSView, let window = view.window else { return false }
      let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
      return floatingViews.allObjects.contains { $0.window === window && $0.containsWindowPoint(center) }
    }

    var onActivate: (() -> Void)?
    var isFloating = false {
      didSet { updateFloatingRegistration() }
    }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateFloatingRegistration()
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        guard let self, self.contains(event), !self.isCoveredByFloatingPane(event) else { return event }
        self.onActivate?()
        return event
      }
    }

    private func contains(_ event: NSEvent) -> Bool {
      guard let window, event.window === window else { return false }
      return containsWindowPoint(event.locationInWindow)
    }

    private func containsWindowPoint(_ point: CGPoint) -> Bool {
      bounds.contains(convert(point, from: nil))
    }

    private func isCoveredByFloatingPane(_ event: NSEvent) -> Bool {
      guard !isFloating else { return false }
      return Self.floatingViews.allObjects.contains { $0 !== self && $0.contains(event) }
    }

    private func updateFloatingRegistration() {
      if isFloating, window != nil {
        Self.floatingViews.add(self)
      } else {
        Self.floatingViews.remove(self)
      }
    }

    isolated deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
