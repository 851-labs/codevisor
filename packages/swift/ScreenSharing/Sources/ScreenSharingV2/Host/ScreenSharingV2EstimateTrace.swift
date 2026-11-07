import Foundation

struct ScreenSharingV2EstimateTrace {
  static let label = "estimateMinMbpsPerSecond"
  static let keptSeconds = 600
  private static let secondNs: Int64 = 1_000_000_000

  private var secondStartNs: Int64?
  private var lowestKbps: UInt64 = .max
  private var seconds: [UInt64] = []

  mutating func observe(estimateKbps: UInt64, atNs nowNs: Int64) -> String? {
    guard let secondStartNs, nowNs - secondStartNs >= Self.secondNs else {
      secondStartNs = secondStartNs ?? nowNs
      lowestKbps = min(lowestKbps, estimateKbps)
      return nil
    }

    seconds.append(lowestKbps)
    if seconds.count > Self.keptSeconds { seconds.removeFirst() }
    self.secondStartNs = nowNs
    lowestKbps = estimateKbps
    return seconds.map { String(format: "%.1f", Double($0) / 1000) }.joined(separator: ",")
  }
}
