import Foundation

/// Bounded collection of per-presentation image ages for one telemetry interval.
public struct RigImageAge: Sendable {
  public struct Summary: Codable, Equatable, Sendable {
    public let count: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double
  }

  public let capacity: Int
  private var agesMilliseconds: [Double] = []
  private var dropped = 0

  public init(capacity: Int = 600) { self.capacity = capacity }

  public mutating func record(ageSeconds: Double) {
    guard ageSeconds.isFinite else { return }
    if agesMilliseconds.count < capacity { agesMilliseconds.append(ageSeconds * 1000) } else { dropped += 1 }
  }

  /// Summarises and clears the interval; nil when nothing was recorded.
  public mutating func take() -> Summary? {
    defer {
      agesMilliseconds.removeAll(keepingCapacity: true)
      dropped = 0
    }
    guard !agesMilliseconds.isEmpty else { return nil }
    let sorted = agesMilliseconds.sorted()
    func percentile(_ fraction: Double) -> Double {
      sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
    return Summary(
      count: sorted.count + dropped, p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95),
      maximumMilliseconds: sorted[sorted.count - 1])
  }
}
