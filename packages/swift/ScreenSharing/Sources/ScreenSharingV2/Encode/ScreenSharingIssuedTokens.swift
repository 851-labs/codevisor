struct ScreenSharingIssuedTokens: Sendable {
  private static let remembered = 64

  private var tokens: [Int: [UInt64]] = [:]

  mutating func remember(_ token: UInt64, tile: Int) {
    tokens[tile] = Array((tokens[tile, default: []] + [token]).suffix(Self.remembered))
  }

  func issued(_ candidates: [UInt64], tile: Int) -> [UInt64] {
    let known = Set(tokens[tile, default: []])
    return candidates.filter(known.contains)
  }
}
