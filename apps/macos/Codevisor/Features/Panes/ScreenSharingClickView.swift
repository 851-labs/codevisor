import AppKit

final class ScreenSharingClickView: NSView {
  var onClick: (() -> Void)?
  var label = ""

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard onClick != nil else { return super.hitTest(point) }

    return super.hitTest(point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    guard let onClick else { return super.mouseDown(with: event) }

    onClick()
  }

  override func isAccessibilityElement() -> Bool { onClick != nil }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { label }

  override func accessibilityPerformPress() -> Bool {
    guard let onClick else { return false }

    onClick()
    return true
  }
}
