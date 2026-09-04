#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    /// A scoped shortcut/focused-row fallback. Field-editor commands are
    /// handled by NSSearchFieldDelegate, after native text-input processing.
    struct KeyMonitor: NSViewRepresentable {
      let host: Host
      func makeCoordinator() -> Coordinator { Coordinator(host: host) }
      func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
      }
      func updateNSView(_ view: NSView, context: Context) { context.coordinator.host = host }
      static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

      @MainActor
      final class Coordinator {
        var host: Host
        weak var view: NSView?
        private var monitor: Any?
        init(host: Host) { self.host = host }
        func install() {
          guard monitor == nil else { return }
          monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return host.handleEvent(event, window: host.inputField?.window ?? view?.window) ? nil : event
          }
        }
        func remove() {
          if let monitor { NSEvent.removeMonitor(monitor) }
          monitor = nil
        }
      }
    }
  }
#endif
