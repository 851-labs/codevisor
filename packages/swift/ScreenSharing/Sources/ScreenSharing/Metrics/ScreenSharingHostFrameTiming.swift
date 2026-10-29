import Foundation

public struct ScreenSharingHostFrameTiming: Equatable, Sendable {
  public static let maximumDurationUs: Int64 = (1 << 35) - 1

  public let clock: UInt64
  public let captureUs: Int64
  public let hostQueueUs: Int64
  public let encodeUs: Int64

  package init(clock: UInt64, captureUs: Int64, hostQueueUs: Int64, encodeUs: Int64) {
    self.clock = clock
    self.captureUs = Self.bounded(captureUs)
    self.hostQueueUs = Self.bounded(hostQueueUs)
    self.encodeUs = Self.bounded(encodeUs)
  }

  package init(sourceNs: Int64, capturedNs: Int64, submittedNs: Int64, encodedNs: Int64, clock: UInt64) {
    self.init(
      clock: clock, captureUs: (capturedNs - sourceNs) / 1000, hostQueueUs: (submittedNs - capturedNs) / 1000,
      encodeUs: (encodedNs - submittedNs) / 1000)
  }

  private static func bounded(_ microseconds: Int64) -> Int64 {
    min(maximumDurationUs, max(0, microseconds))
  }
}
