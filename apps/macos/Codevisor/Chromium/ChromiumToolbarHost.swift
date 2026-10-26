import AppKit
import CodevisorUI
import SwiftUI

final class ChromiumToolbarHost: NSHostingView<ChromiumBrowserToolbarContent> {
  weak var model: ChromiumBrowserModel?
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
      NSApp.modalWindow == nil, event.window === window, let model,
      model.webView?.hasPageFocus == true || toolbarHasFocus
    else { return event }
    if let command = ShortcutCatalog.browserZoomCommand(for: event) {
      model.zoom(command)
      return nil
    }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
    case ("r", .command): model.reload()
    case ("r", [.command, .shift]): model.reload(ignoringCache: true)
    case ("l", .command): model.address.focus()
    case ("f", .command): model.find.present()
    case ("g", .command): model.find.findNext()
    case ("g", [.command, .shift]): model.find.findPrevious()
    case ("[", .command): model.goBack()
    case ("]", .command): model.goForward()
    default: return event
    }
    return nil
  }

  private var toolbarHasFocus: Bool {
    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return true }
    let editor = window?.firstResponder as? NSTextView
    return (editor?.delegate as? NSView)?.isDescendant(of: self) == true
  }
  isolated deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}
