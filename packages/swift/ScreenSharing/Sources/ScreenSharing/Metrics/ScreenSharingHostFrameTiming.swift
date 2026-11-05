import Foundation

public struct ScreenSharingHostFrameTiming: Equatable, Sendable {
  public static let maximumDurationUs: Int64 = (1 << 35) - 1

  public let clock: UInt64
  public let captureUs: Int64
  public let hostQueueUs: Int64
  public let encodeUs: Int64
  public let handOffUs: Int64

  package init(clock: UInt64, captureUs: Int64, hostQueueUs: Int64, encodeUs: Int64, handOffUs: Int64) {
    self.clock = clock
    self.captureUs = Self.bounded(captureUs)
    self.hostQueueUs = Self.bounded(hostQueueUs)
    self.encodeUs = Self.bounded(encodeUs)
    self.handOffUs = Self.bounded(handOffUs)
  }

  private static func bounded(_ microseconds: Int64) -> Int64 {
    min(maximumDurationUs, max(0, microseconds))
  }
}
