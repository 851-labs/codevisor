import CoreGraphics
import Foundation

/// How much host work a transcript surface may do on one display frame.
/// Shared by both virtualizers; the numbers are the ones each platform had
/// hard-coded.
public struct TranscriptFrameBudget: Equatable, Sendable {
  /// New row hosts that may be installed this frame.
  public let mountsPerFrame: Int
  /// Wall-clock budget for mounting work this frame, in seconds.
  public let workBudget: TimeInterval

  /// - Parameters:
  ///   - maximumFramesPerSecond: The screen's refresh rate; above 60 Hz the
  ///     budget is halved to keep frame time.
  ///   - isInteracting: Whether the user is actively scrolling. UIKit's
  ///     virtualizer always passes true — momentum scrolling can begin at
  ///     any time — while AppKit can afford a larger idle budget.
  public init(maximumFramesPerSecond: Int, isInteracting: Bool) {
    let isHighRefresh = maximumFramesPerSecond > 60
    if isInteracting {
      mountsPerFrame = isHighRefresh ? 2 : 4
      workBudget = isHighRefresh ? 0.0025 : 0.005
    } else {
      mountsPerFrame = isHighRefresh ? 6 : 8
      workBudget = isHighRefresh ? 0.004 : 0.008
    }
  }

  /// Directional runway rows whose first layout may be completed this
  /// frame. Faster projected motion earns more preparation because the
  /// rows are about to become visible.
  public static func runwayPreparationsPerFrame(
    maximumFramesPerSecond: Int,
    projectedDistance: CGFloat,
    viewportHeight: CGFloat
  ) -> Int {
    let isHighRefresh = maximumFramesPerSecond > 60
    let viewportHeight = max(1, viewportHeight)
    let distance = abs(projectedDistance)
    if distance >= viewportHeight {
      return isHighRefresh ? 3 : 4
    }
    if distance >= viewportHeight * 0.35 {
      return isHighRefresh ? 2 : 3
    }
    return isHighRefresh ? 1 : 2
  }
}
