import Foundation

enum StreamingTextAnimationSpec {
  static let fadeDuration: TimeInterval = 0.150
  static let emojiStabilizationDelay: TimeInterval = 0.050
  static let minimumTargetQueueLead: TimeInterval = 0.055
  static let defaultTargetQueueLead: TimeInterval = 0.100
  static let maximumTargetQueueLead: TimeInterval = 0.350
  static let fastestSegmentDelay: TimeInterval = 0
  static let queueHeadSpacing: TimeInterval = 0.008
  static let minimumSlowestSegmentDelay: TimeInterval = 0.032
  static let maximumSlowestSegmentDelay: TimeInterval = 0.120
  static let minimumStartupQueueLead: TimeInterval = 0.020
  static let maximumStartupQueueLead: TimeInterval = 0.100
  static let minimumArrivalSampleGap: TimeInterval = 0.010
  static let maximumArrivalSampleGap: TimeInterval = 0.900
  static let initialChunkBaseLead: TimeInterval = 0.050
  static let initialChunkCharacterLead: TimeInterval = 0.0008
  static let maximumInitialChunkLead: TimeInterval = 0.150
  static let gapSmoothingAlpha = 0.35
  static let jitterSmoothingAlpha = 0.25
  static let queueLeadRiseAlpha = 0.55
  static let queueLeadFallAlpha = 0.12
  static let jitterMultiplier = 1.5
  static let fadeCurveX1 = 0.37
  static let fadeCurveY1 = 0.55
  static let fadeCurveX2 = 0.86
  static let fadeCurveY2 = 0.88

  static func clampedTargetQueueLead(_ lead: TimeInterval) -> TimeInterval {
    min(maximumTargetQueueLead, max(minimumTargetQueueLead, lead))
  }

  static func initialTargetQueueLead(forCharacterCount count: Int) -> TimeInterval {
    clampedTargetQueueLead(
      min(
        maximumInitialChunkLead,
        initialChunkBaseLead + Double(max(0, count)) * initialChunkCharacterLead
      ))
  }

  static func startupQueueLead(forTargetQueueLead targetQueueLead: TimeInterval) -> TimeInterval {
    min(
      maximumStartupQueueLead,
      max(minimumStartupQueueLead, targetQueueLead * 0.35)
    )
  }

  static func slowestSegmentDelay(forTargetQueueLead targetQueueLead: TimeInterval) -> TimeInterval {
    min(
      maximumSlowestSegmentDelay,
      max(minimumSlowestSegmentDelay, targetQueueLead * 0.45)
    )
  }

  static func segmentDelay(
    revealedCharacterCount: Int,
    backlogCharacterCount: Int,
    targetQueueLead: TimeInterval
  ) -> TimeInterval {
    guard backlogCharacterCount > 0 else { return fastestSegmentDelay }
    let desired =
      targetQueueLead
      * Double(max(1, revealedCharacterCount))
      / Double(backlogCharacterCount)
    return min(
      slowestSegmentDelay(forTargetQueueLead: targetQueueLead),
      max(fastestSegmentDelay, desired)
    )
  }
}
