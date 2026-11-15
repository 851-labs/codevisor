import AppKit

@MainActor
final class ScreenSharingHostIndicator: NSObject {
  private var item: NSStatusItem?
  private var stop: (() -> Void)?
  private var viewer: String?

  func show(display: String, viewer: String?, stop: @escaping () -> Void) {
    hide()
    self.stop = stop
    self.viewer = viewer
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Screen Sharing active")
    item.button?.title = " Sharing"
    let menu = NSMenu()
    menu.addItem(withTitle: Self.title(display, viewer: viewer), action: nil, keyEquivalent: "")
    let end = menu.addItem(withTitle: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: "")
    end.target = self
    item.menu = menu
    self.item = item
  }
  func setDisplay(_ display: String) {
    item?.menu?.items.first?.title = Self.title(display, viewer: viewer)
  }
  static func title(_ display: String, viewer: String?) -> String {
    "Sharing \(display) with \(viewer ?? "another device")"
  }
  func setControlling(_ active: Bool) {
    item?.button?.title = active ? " Controlled" : " Sharing"
  }
  func hide() {
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil; stop = nil; viewer = nil
  }
  @objc private func stopSharing() { stop?() }
}
