import AppKit
import SwiftUI

struct FirstLaunchKeyboard: NSViewRepresentable {
  let isCovering: Bool
  let onReturn: () -> Void

  func makeNSView(context: Context) -> KeyCatcherView {
    let view = KeyCatcherView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: KeyCatcherView, context: Context) {
    view.isCovering = isCovering
    view.onReturn = onReturn
  }

  final class KeyCatcherView: NSView {
    var isCovering = true
    var onReturn: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, self.isCovering, let window = self.window, event.window === window,
          event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        else { return event }
        if event.keyCode == 36 || event.keyCode == 76 { self.onReturn?() }
        return nil
      }
    }

    isolated deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
