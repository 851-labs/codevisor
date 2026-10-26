import AppKit
import SwiftUI

struct CommandPaletteClickMonitor: NSViewRepresentable {
  let onClickOutside: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onClickOutside: onClickOutside) }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(watching: view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.onClickOutside = onClickOutside
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.remove()
  }

  final class Coordinator {
    var onClickOutside: () -> Void
    private weak var view: NSView?
    private var monitor: Any?
    private static let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    init(onClickOutside: @escaping () -> Void) {
      self.onClickOutside = onClickOutside
    }

    func install(watching view: NSView) {
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: Self.clicks) { [weak self] event in
        self?.handle(event)
        return event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handle(_ event: NSEvent) {
      guard let view, event.window === view.window, isOutside(event, view) else { return }

      onClickOutside()
    }

    private func isOutside(_ event: NSEvent, _ view: NSView) -> Bool {
      !view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
  }
}
