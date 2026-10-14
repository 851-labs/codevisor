import CoreGraphics
import Foundation

public struct TranscriptFrameBudget: Equatable, Sendable {
  public let mountsPerFrame: Int
  public let workBudget: TimeInterval

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
