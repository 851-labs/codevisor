struct ScreenSharingV2Refinement {
  private let passes: Int
  private let gapNs: Int64
  private var remaining: [Int: Int] = [:]
  private var encodedNs: [Int: Int64] = [:]

  init(passes: Int = ScreenSharingV2Profile.refinementPasses, gapNs: Int64 = ScreenSharingV2Profile.refinementGapNs) {
    self.passes = passes
    self.gapNs = gapNs
  }

  mutating func changed(_ tiles: Set<Int>, atNs nowNs: Int64) {
    for tile in tiles {
      remaining[tile] = passes
      encodedNs[tile] = nowNs
    }
  }

  mutating func refined(_ tiles: Set<Int>, atNs nowNs: Int64) {
    for tile in tiles {
      let left = (remaining[tile] ?? 1) - 1
      remaining[tile] = left > 0 ? left : nil
      encodedNs[tile] = nowNs
    }
  }

  mutating func settled(_ tile: Int) {
    remaining[tile] = nil
  }

  func due(atNs nowNs: Int64, excluding busy: Set<Int>) -> Set<Int> {
    Set(remaining.keys.filter { !busy.contains($0) && nowNs - (encodedNs[$0] ?? 0) >= gapNs })
  }

  func next(atNs nowNs: Int64, excluding busy: Set<Int>) -> Int? {
    remaining.keys.filter { !busy.contains($0) && nowNs - (encodedNs[$0] ?? 0) >= gapNs }
      .min { (encodedNs[$0] ?? 0, $0) < (encodedNs[$1] ?? 0, $1) }
  }

  func nextDueNs(excluding busy: Set<Int>) -> Int64? {
    remaining.keys.filter { !busy.contains($0) }.compactMap { encodedNs[$0].map { $0 + gapNs } }.min()
  }

  mutating func clear() {
    remaining = [:]
    encodedNs = [:]
  }
}
