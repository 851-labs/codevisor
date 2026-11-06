import AppKit
import SwiftUI

struct WindowFocusReader: NSViewRepresentable {
  let onKeyChange: @MainActor (Bool) -> Void
  let onClose: @MainActor () -> Void

  func makeNSView(context: Context) -> Probe {
    Probe(onKeyChange: onKeyChange, onClose: onClose)
  }

  func updateNSView(_ nsView: Probe, context: Context) {
    nsView.onKeyChange = onKeyChange
    nsView.onClose = onClose
  }

  final class Probe: NSView {
    var onKeyChange: @MainActor (Bool) -> Void
    var onClose: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    init(onKeyChange: @escaping @MainActor (Bool) -> Void, onClose: @escaping @MainActor () -> Void) {
      self.onKeyChange = onKeyChange
      self.onClose = onClose
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }

      observers = [
        observe(NSWindow.didBecomeKeyNotification, of: window) { $0.onKeyChange(true) },
        observe(NSWindow.didResignKeyNotification, of: window) { $0.onKeyChange(false) },
        observe(NSWindow.willCloseNotification, of: window) { $0.onClose() },
      ]
      onKeyChange(window.isKeyWindow)
    }

    private func observe(
      _ name: Notification.Name, of window: NSWindow, _ handle: @escaping @MainActor (Probe) -> Void
    ) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          handle(self)
        }
      }
    }
  }
}
