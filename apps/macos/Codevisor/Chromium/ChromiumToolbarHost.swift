import AppKit
import SwiftUI

/// CEF may consume key equivalents before the SwiftUI menu sees them. Scope
/// browser shortcuts to the active toolbar's key window, including page focus.
final class ChromiumToolbarHost: NSHostingView<ChromiumBrowserToolbarContent> {
  var focusAddress: (() -> Void)?
  var zoom: ((BrowserZoomCommand) -> Void)?
  var pageHasFocus: (() -> Bool)?
  private var keyMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    guard window != nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleKeyEvent(event)
    }
  }

  func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
    guard let window, window.isKeyWindow, window.attachedSheet == nil,
      NSApp.modalWindow == nil, event.window === window
    else { return event }
    if let command = ShortcutCatalog.browserZoomCommand(for: event),
      pageHasFocus?() == true || toolbarHasFocus
    {
      zoom?(command)
      return nil
    }
    guard
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "l"
    else { return event }
    focusAddress?()
    return nil
  }

  private var toolbarHasFocus: Bool {
    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return true }
    // NSTextField uses the window's shared field editor as first responder.
    let editor = window?.firstResponder as? NSTextView
    return (editor?.delegate as? NSView)?.isDescendant(of: self) == true
  }
  deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}
