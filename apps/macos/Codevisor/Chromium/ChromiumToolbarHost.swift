import AppKit
import SwiftUI

/// CEF may consume key equivalents before the SwiftUI menu sees them. Scope
/// Open Location to the active toolbar's key window, including page focus.
final class ChromiumToolbarHost: NSHostingView<ChromiumBrowserToolbarContent> {
  var focusAddress: (() -> Void)?
  private var keyMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    guard window != nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, window.isKeyWindow, window.attachedSheet == nil,
        event.window === window,
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "l"
      else { return event }
      self.focusAddress?()
      return nil
    }
  }
  deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}
