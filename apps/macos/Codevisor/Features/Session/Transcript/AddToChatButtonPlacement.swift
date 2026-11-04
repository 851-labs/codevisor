import CoreGraphics

nonisolated struct AddToChatButtonPlacement {
  static let gap: CGFloat = 2

  let line: CGRect
  let anchorX: CGFloat
  let bounds: CGRect

  init?(lineRects: [CGRect], pointer: CGPoint?, bounds: CGRect) {
    guard let line = Self.anchorLine(in: lineRects, near: pointer) else { return nil }

    self.line = line
    self.anchorX = pointer?.x ?? line.maxX
    self.bounds = bounds
  }

  func origin(for size: CGSize) -> CGPoint {
    CGPoint(x: x(for: size.width), y: y(for: size.height))
  }

  private func x(for width: CGFloat) -> CGFloat {
    clamped(anchorX - width / 2, from: bounds.minX, to: bounds.maxX - width)
  }

  private func y(for height: CGFloat) -> CGFloat {
    let above = line.minY - Self.gap - height
    let preferred = above >= bounds.minY ? above : line.maxY + Self.gap
    return clamped(preferred, from: bounds.minY, to: bounds.maxY - height)
  }

  private func clamped(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
    min(max(value, lower), max(lower, upper))
  }

  private static func anchorLine(in rects: [CGRect], near pointer: CGPoint?) -> CGRect? {
    guard let pointer else { return rects.last }

    return rects.min { distance(from: $0, to: pointer) < distance(from: $1, to: pointer) }
  }

  private static func distance(from rect: CGRect, to point: CGPoint) -> (vertical: CGFloat, horizontal: CGFloat) {
    (
      vertical: max(0, rect.minY - point.y, point.y - rect.maxY),
      horizontal: max(0, rect.minX - point.x, point.x - rect.maxX)
    )
  }
}
