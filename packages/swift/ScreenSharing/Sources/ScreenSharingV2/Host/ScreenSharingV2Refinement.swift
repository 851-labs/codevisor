struct ScreenSharingV2Refinement {
  private let passes: Int
  private let gapNs: Int64
  private var remaining: [Int: Int] = [:]
  private var encodedNs: [Int: Int64] = [:]
  private var changedBy: [Int: UInt32] = [:]

  init(passes: Int = ScreenSharingV2Profile.refinementPasses, gapNs: Int64 = ScreenSharingV2Profile.refinementGapNs) {
    self.passes = passes
    self.gapNs = gapNs
  }

  mutating func changed(_ tiles: Set<Int>, by update: UInt32, atNs nowNs: Int64) {
    for tile in tiles {
      remaining[tile] = passes
      encodedNs[tile] = nowNs
      changedBy[tile] = update
    }
  }

  mutating func refined(_ tiles: Set<Int>, atNs nowNs: Int64) {
    for tile in tiles {
      let left = (remaining[tile] ?? 1) - 1
      remaining[tile] = left > 0 ? left : nil
      encodedNs[tile] = nowNs
    }
  }

  mutating func settled(_ tile: Int, by update: UInt32) {
    guard Int32(bitPattern: update &- (changedBy[tile] ?? update)) >= 0 else { return }

    remaining[tile] = nil
  }

  func next(atNs nowNs: Int64, excluding busy: Set<Int>, aligned: (Int64) -> Int64 = { $0 }) -> Int? {
    remaining.keys.filter { !busy.contains($0) && nowNs >= aligned((encodedNs[$0] ?? 0) + gapNs) }
      .min { (encodedNs[$0] ?? 0, $0) < (encodedNs[$1] ?? 0, $1) }
  }

  func nextDueNs(excluding busy: Set<Int>, aligned: (Int64) -> Int64 = { $0 }) -> Int64? {
    remaining.keys.filter { !busy.contains($0) }.compactMap { encodedNs[$0].map { aligned($0 + gapNs) } }.min()
  }

  mutating func clear() {
    remaining = [:]
    encodedNs = [:]
    changedBy = [:]
  }
}
