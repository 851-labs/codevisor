import CoreGraphics

enum PointerParking {
  private static let bottomMargin = 60.0

  static func parkAwayFromTheMenuBar() {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let point = CGPoint(x: bounds.midX, y: bounds.maxY - bottomMargin)
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }
}
