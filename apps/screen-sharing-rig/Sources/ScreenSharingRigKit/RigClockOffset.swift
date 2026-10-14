import Foundation

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
    public var interval: (low: Double, high: Double)? {
      guard receivedAtSeconds >= sentAtSeconds, hostSentAtSeconds >= hostReceivedAtSeconds else { return nil }
      let low = hostSentAtSeconds - receivedAtSeconds
      let high = hostReceivedAtSeconds - sentAtSeconds
      return low <= high ? (low, high) : nil
    }
  }

  public let offsetSeconds: Double
  public let errorSeconds: Double
  public let sampleCount: Int

  public init?(samples: [Sample]) {
    let intervals = samples.compactMap(\.interval)
    guard let best = intervals.min(by: { ($0.high - $0.low) < ($1.high - $1.low) }) else { return nil }
    offsetSeconds = (best.low + best.high) / 2
    errorSeconds = (best.high - best.low) / 2
    sampleCount = intervals.count
  }

  public func imageAgeSeconds(sourceTimestampNs: Int64, presentedAtSeconds: Double) -> Double {
    presentedAtSeconds - (Double(sourceTimestampNs) / 1_000_000_000 - offsetSeconds)
  }
}
