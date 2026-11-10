import AppKit
import SwiftUI

struct ClickOutsideMonitor: NSViewRepresentable {
  let isActive: Bool
  let onClickOutside: () -> Void

  func makeNSView(context: Context) -> MonitorView {
    MonitorView()
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.onClickOutside = isActive ? onClickOutside : nil
  }

  static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
    view.onClickOutside = nil
  }

  final class MonitorView: NSView {
    private static let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private var monitor: Any?

    var onClickOutside: (() -> Void)? {
      didSet { updateMonitor() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    private func updateMonitor() {
      if onClickOutside == nil {
        stop()
      } else {
        start()
      }
    }

    private func start() {
      guard monitor == nil else { return }

      monitor = NSEvent.addLocalMonitorForEvents(matching: Self.clicks) { [weak self] event in
        self?.notifyIfOutside(event)
        return event
      }
    }

    private func stop() {
      guard let monitor else { return }

      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    private func notifyIfOutside(_ event: NSEvent) {
      guard let window, event.window === window else { return }
      guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }

      onClickOutside?()
    }
  }
}
