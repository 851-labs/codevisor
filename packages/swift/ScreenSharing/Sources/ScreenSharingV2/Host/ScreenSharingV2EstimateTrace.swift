import Foundation

public enum ScreenSharingV2EstimateTraceLabel {
  public static let name = "estimateMinMbpsPerSecond"
  public static let gap = "-"
}

struct ScreenSharingV2EstimateTrace {
  static let keptSeconds = 120
  private static let secondNs: Int64 = 1_000_000_000

  private var secondStartNs: Int64?
  private var lowestKbps: UInt64 = .max
  private var seconds: [UInt64?] = []

  mutating func observe(estimateKbps: UInt64, atNs nowNs: Int64) -> String? {
    guard let secondStartNs, nowNs - secondStartNs >= Self.secondNs else {
      secondStartNs = secondStartNs ?? nowNs
      lowestKbps = min(lowestKbps, estimateKbps)
      return nil
    }

    seconds.append(lowestKbps)
    let silentSeconds = Int((nowNs - secondStartNs) / Self.secondNs) - 1
    seconds += [UInt64?](repeating: nil, count: min(silentSeconds, Self.keptSeconds))
    seconds.removeFirst(max(0, seconds.count - Self.keptSeconds))
    self.secondStartNs = nowNs
    lowestKbps = estimateKbps
    return seconds.map { $0.map { String(format: "%.1f", Double($0) / 1000) } ?? ScreenSharingV2EstimateTraceLabel.gap }
      .joined(separator: ",")
  }
}
