import CoreGraphics

enum DiffViewportMetrics {
  static let maximumHeight: CGFloat = 320
}

enum DiffScrollConsumptionPolicy {
  /// Whether a bounded viewport can move in the requested content direction.
  /// Negative deltas move toward the start; positive deltas move toward the end.
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
