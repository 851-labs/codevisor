import AppKit
import CodevisorUI
import SwiftUI

/// A detached workspace browser pane. Selecting its sidebar tab returns the
/// same live page to the workspace; closing the window closes that pane.
@MainActor
final class ChromiumBrowserWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  private let model: ChromiumBrowserModel
  private var keyMonitor: Any?
  private let navigation = NSToolbarItem.Identifier("browser.navigation")
  private let address = NSToolbarItem.Identifier("browser.address")

  init(model: ChromiumBrowserModel) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = model.title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.minSize = NSSize(width: 600, height: 400)
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "workspace.browser")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.centeredItemIdentifiers = [address]
    window.toolbar = toolbar
    let content = NSHostingController(
      rootView: ChromiumBrowserPaneView(model: model, isDetachedWindow: true)
        .focusedSceneValue(\.browserPage, model))
    content.sizingOptions = []
    window.contentViewController = content
    window.setContentSize(NSSize(width: 1100, height: 800))
    window.center()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, event.window === window,
        window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil
      else { return event }
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.charactersIgnoringModifiers?.lowercased() == "r",
        modifiers == [.command, .shift]
      {
        self.model.reload(ignoringCache: true)
        return nil
      }
      guard modifiers == .command else { return event }
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "l": self.model.focusAddress()
      case "r": self.model.reload()
      case "w": window.performClose(nil)
      default: return event
      }
      return nil
    }
  }

  required init?(coder: NSCoder) { nil }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [navigation, .flexibleSpace, address, .flexibleSpace]
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    if identifier == navigation {
      item.view = NSHostingView(rootView: ChromiumBrowserNavigationButtons(model: model))
    } else if identifier == address {
      let host = ChromiumToolbarHost(rootView: ChromiumBrowserToolbarContent(model: model))
      host.focusAddress = { [weak model] in model?.focusAddress() }
      host.reload = { [weak model] in model?.reload(ignoringCache: $0) }
      host.zoom = { [weak model] in model?.zoom($0) }
      host.pageHasFocus = { [weak model] in model?.webView?.hasPageFocus == true }
      host.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        host.widthAnchor.constraint(lessThanOrEqualToConstant: 850),
        host.heightAnchor.constraint(equalToConstant: 32),
      ])
      host.setFrameSize(NSSize(width: 650, height: 32))
      item.view = host
      item.visibilityPriority = .high
    } else {
      return nil
    }
    return item
  }

  func windowWillClose(_ notification: Notification) {
    removeMonitor()
    model.setVisible(false)
    model.windowClosed()
  }

  func detach() {
    removeMonitor()
    window?.delegate = nil
    window?.contentViewController = nil
    window?.close()
  }
  private func removeMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
  }
  deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}
