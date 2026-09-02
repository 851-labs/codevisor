import CoreGraphics

/// Decides how a transcript should respond when its viewport height changes.
///
/// Keyboard avoidance, rotation, and container resizing all reach the native
/// transcript as viewport changes. A transcript parked at the newest content
/// should keep that bottom edge pinned as the viewport moves. Once the user
/// has moved away from the bottom, preserving the raw content offset keeps the
/// content under their eyes stationary instead.
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
