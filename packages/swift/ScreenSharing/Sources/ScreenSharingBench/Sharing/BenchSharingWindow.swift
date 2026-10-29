public struct BenchSharingWindow: Sendable, Equatable {
  public static let warmUpNs: Int64 = 5_000_000_000
  public static let tailNs: Int64 = 2_000_000_000

  public let startNs: Int64
  public let endNs: Int64

  public init?(spans: [ClosedRange<Int64>], warmUpNs: Int64 = warmUpNs, tailNs: Int64 = tailNs) {
    guard let latestStart = spans.map(\.lowerBound).max(), let earliestEnd = spans.map(\.upperBound).min() else {
      return nil
    }

    startNs = latestStart + warmUpNs
    endNs = earliestEnd - tailNs
    guard endNs > startNs else { return nil }
  }

  public func contains(_ ns: Int64) -> Bool {
    (startNs...endNs).contains(ns)
  }

  public var durationMs: Double {
    Double(endNs - startNs) / 1_000_000
  }
}
