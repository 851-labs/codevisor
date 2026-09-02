import CoreGraphics
import Foundation

/// Which rows a transcript surface should keep mounted around the viewport.
/// Wraps `TranscriptVirtualWindowPolicy` with the two rules both platforms
/// layer on top of it: a symmetric runway until the initial presentation is
/// ready, and the invariant that the loaded viewport is always part of the
/// retained window.
public struct TranscriptWindowPlanner: Sendable {
  public var policy: TranscriptVirtualWindowPolicy
  /// Runway on either side of the viewport, in viewport heights, while the
  /// initial presentation gate is still closed.
  public var initialRunwayViewportCount: CGFloat

  public init(policy: TranscriptVirtualWindowPolicy, initialRunwayViewportCount: CGFloat) {
    self.policy = policy
    self.initialRunwayViewportCount = initialRunwayViewportCount
  }

  /// The index range to mount for the current viewport.
  public func plannedRange(
    layout: VirtualTranscriptLayout,
    distanceFromBottom: CGFloat,
    viewportHeight: CGFloat,
    scrollDelta: CGFloat,
    isInitialPresentationReady: Bool,
    currentTargetKeys: Set<String>
  ) -> Range<Int> {
    guard isInitialPresentationReady else {
      let runway = viewportHeight * initialRunwayViewportCount
      return layout.visibleRange(
        distanceFromBottom: distanceFromBottom,
        viewportHeight: viewportHeight,
        runwayBefore: runway,
        runwayAfter: runway
      )
    }
    return policy.targetRange(
      layout: layout,
      distanceFromBottom: distanceFromBottom,
      viewportHeight: viewportHeight,
      scrollDelta: scrollDelta,
      currentRange: layout.contiguousRange(of: currentTargetKeys)
    )
  }

  /// The keys to retain for a target window. A restored or rapidly changing
  /// target should normally contain the viewport, but visible coverage is
  /// an invariant even if it does not.
  public static func targetKeys(
    layout: VirtualTranscriptLayout,
    targetRange: Range<Int>,
    visibleRange: Range<Int>
  ) -> Set<String> {
    layout.keys(in: targetRange).union(layout.keys(in: visibleRange))
  }
}
