import CoreFoundation

struct ScreenSharingVCPRate {
  static let windowSeconds = 0.05
  static let ladder = 20_800_000...60_000_000
  static let shortestFrameGapNs: Int64 = 1_000_000_000 / 240 + 1
  static let highestFrameQP = 28

  let bitsPerSecond: Int
  let tiles: Int

  var tileBitsPerSecond: Int { min(Self.ladder.upperBound, bitsPerSecond) / tiles }
  var tileWindowBitsPerSecond: Int { min(Self.ladder.upperBound, max(Self.ladder.lowerBound, bitsPerSecond)) / tiles }

  static func limits(bitsPerSecond: Int) -> CFArray {
    [Int(Double(bitsPerSecond) * windowSeconds / 8) as CFNumber, windowSeconds as CFNumber] as CFArray
  }
}
