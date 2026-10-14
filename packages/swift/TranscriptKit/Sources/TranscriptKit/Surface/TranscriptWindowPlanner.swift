import CoreGraphics
import Foundation

public struct TranscriptWindowPlanner: Sendable {
  public var policy: TranscriptVirtualWindowPolicy
  public var initialRunwayViewportCount: CGFloat

  public init(policy: TranscriptVirtualWindowPolicy, initialRunwayViewportCount: CGFloat) {
    self.policy = policy
    self.initialRunwayViewportCount = initialRunwayViewportCount
  }

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

  public static func targetKeys(
    layout: VirtualTranscriptLayout,
    targetRange: Range<Int>,
    visibleRange: Range<Int>
  ) -> Set<String> {
    layout.keys(in: targetRange).union(layout.keys(in: visibleRange))
  }
}
