import CoreGraphics

enum DiffViewportMetrics {
  static let maximumHeight: CGFloat = 320
}

enum DiffScrollConsumptionPolicy {
  static func canConsume(
    contentDelta: CGFloat,
    offset: CGFloat,
    contentLength: CGFloat,
    viewportLength: CGFloat,
    tolerance: CGFloat = 0.5
  ) -> Bool {
    guard abs(contentDelta) > tolerance,
      contentLength > viewportLength + tolerance
    else { return false }

    if contentDelta < 0 {
      return offset > tolerance
    }
    return offset + viewportLength < contentLength - tolerance
  }
}
