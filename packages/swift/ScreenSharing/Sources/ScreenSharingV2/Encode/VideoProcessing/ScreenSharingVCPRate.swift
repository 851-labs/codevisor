import CoreFoundation

struct ScreenSharingVCPRate {
  static let windowSeconds = 0.05
  static let highestBitsPerSecond = 60_000_000
  static let nearLosslessFromBitsPerSecond = 20_800_000
  static let shortestFrameGapNs: Int64 = 1_000_000_000 / 240 + 1
  static let highestFrameQP = 28
  static let highestRefinementQP = 6
  static let convergedRefinementBytes = 200

  let bitsPerSecond: Int
  let tiles: Int

  var refinesNearLossless: Bool { bitsPerSecond >= Self.nearLosslessFromBitsPerSecond }

  func highestQP(refining: Bool) -> Int {
    refining && refinesNearLossless ? Self.highestRefinementQP : Self.highestFrameQP
  }

  var tileBitsPerSecond: Int { min(Self.highestBitsPerSecond, bitsPerSecond) / tiles }
  var tileWindowBitsPerSecond: Int {
    min(Self.highestBitsPerSecond, max(ScreenSharingV2Profile.minimumBitrate, bitsPerSecond)) / tiles
  }

  static func limits(bitsPerSecond: Int) -> CFArray {
    [Int(Double(bitsPerSecond) * windowSeconds / 8) as CFNumber, windowSeconds as CFNumber] as CFArray
  }
}
