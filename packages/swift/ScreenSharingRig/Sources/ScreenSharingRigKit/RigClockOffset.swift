import Foundation

/// Offset between the host's and the viewer's monotonic clocks (both mach-based, as
/// `CACurrentMediaTime` and the capture timestamps are), derived from request-bracketed
/// samples without assuming symmetric network delay: for one exchange the viewer sends at
/// `t0`, the host receives at `r` and replies at `s`, and the viewer receives at `t1`, so
/// `host - viewer` lies in `[s - t1, r - t0]`. The tightest interval wins.
public struct RigClockOffset: Equatable, Sendable {
  public struct Sample: Equatable, Sendable {
    public let sentAtSeconds: Double
    public let hostReceivedAtSeconds: Double
    public let hostSentAtSeconds: Double
    public let receivedAtSeconds: Double
    public init(
      sentAtSeconds: Double, hostReceivedAtSeconds: Double, hostSentAtSeconds: Double, receivedAtSeconds: Double
    ) {
      self.sentAtSeconds = sentAtSeconds
      self.hostReceivedAtSeconds = hostReceivedAtSeconds
      self.hostSentAtSeconds = hostSentAtSeconds
      self.receivedAtSeconds = receivedAtSeconds
    }
    /// The interval `[low, high]` containing `host - viewer`, or nil for an unusable sample.
    public var interval: (low: Double, high: Double)? {
      guard receivedAtSeconds >= sentAtSeconds, hostSentAtSeconds >= hostReceivedAtSeconds else { return nil }
      let low = hostSentAtSeconds - receivedAtSeconds
      let high = hostReceivedAtSeconds - sentAtSeconds
      return low <= high ? (low, high) : nil
    }
  }

  /// `host - viewer`, seconds.
  public let offsetSeconds: Double
  /// Half the width of the tightest interval, seconds; the uncertainty of every derived age.
  public let errorSeconds: Double
  public let sampleCount: Int

  public init?(samples: [Sample]) {
    let intervals = samples.compactMap(\.interval)
    guard let best = intervals.min(by: { ($0.high - $0.low) < ($1.high - $1.low) }) else { return nil }
    offsetSeconds = (best.low + best.high) / 2
    errorSeconds = (best.high - best.low) / 2
    sampleCount = intervals.count
  }

  /// Age of content captured at `sourceTimestampNs` on the host, seen on the viewer at `presentedAtSeconds`.
  public func imageAgeSeconds(sourceTimestampNs: Int64, presentedAtSeconds: Double) -> Double {
    presentedAtSeconds - (Double(sourceTimestampNs) / 1_000_000_000 - offsetSeconds)
  }
}
