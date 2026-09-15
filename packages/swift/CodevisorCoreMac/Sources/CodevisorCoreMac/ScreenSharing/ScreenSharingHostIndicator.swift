import AppKit

@MainActor
final class ScreenSharingHostIndicator: NSObject {
  private var item: NSStatusItem?
  private var stop: (() -> Void)?

  func show(display: String, stop: @escaping () -> Void) {
    hide()
    self.stop = stop
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Screen Sharing active")
    item.button?.title = " Sharing"
    let menu = NSMenu()
    menu.addItem(withTitle: "Sharing \(display)", action: nil, keyEquivalent: "")
    let end = menu.addItem(withTitle: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: "")
    end.target = self
    item.menu = menu
    self.item = item
  }
  func setControlling(_ active: Bool) {
    item?.button?.title = active ? " Controlled" : " Sharing"
  }
  func hide() {
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil; stop = nil
  }
  @objc private func stopSharing() { stop?() }
}
