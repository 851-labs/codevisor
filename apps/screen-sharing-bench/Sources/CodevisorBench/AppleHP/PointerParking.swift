import CoreGraphics

enum PointerParking {
  private static let bottomMargin = 60.0

  static func parkAwayFromTheMenuBar(on display: CGDirectDisplayID) {
    let bounds = CGDisplayBounds(display)
    let point = CGPoint(x: bounds.midX, y: bounds.maxY - bottomMargin)
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }
}
