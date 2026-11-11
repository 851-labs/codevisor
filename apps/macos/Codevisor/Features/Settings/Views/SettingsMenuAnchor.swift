import AppKit

final class SettingsMenuAnchor {
  private static let menuGap: CGFloat = 4

  weak var view: NSView?

  func popUp(_ menu: NSMenu) {
    guard let view else { return }

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.menuGap), in: view)
  }
}
