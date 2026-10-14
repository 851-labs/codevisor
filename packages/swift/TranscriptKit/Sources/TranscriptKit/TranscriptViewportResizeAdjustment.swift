import CoreGraphics

public enum TranscriptViewportResizeAdjustment: Sendable, Equatable {
  case pinToBottom
  case keepContentOffset

  public static func resolve(
    previousDistanceFromBottom: CGFloat,
    atBottomThreshold: CGFloat,
    isUserInteracting: Bool
  ) -> Self {
    guard !isUserInteracting,
      previousDistanceFromBottom <= max(0, atBottomThreshold)
    else { return .keepContentOffset }
    return .pinToBottom
  }
}
