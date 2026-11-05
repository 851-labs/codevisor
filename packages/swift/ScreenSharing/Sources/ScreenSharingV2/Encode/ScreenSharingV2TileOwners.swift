struct ScreenSharingV2TileOwners: Sendable {
  typealias Owner = ScreenSharingV2EncoderRoute.Choice

  private static let rememberedTokens = 64

  private var owners: [Int: Owner]
  private var issued: [Owner: [Int: [UInt64]]] = [:]

  init(tiles: Set<Int>, owner: Owner) {
    owners = Dictionary(uniqueKeysWithValues: tiles.map { ($0, owner) })
  }

  func owns(_ tile: Int, _ owner: Owner) -> Bool {
    owners[tile] == owner
  }

  mutating func claim(_ tiles: Set<Int>, for owner: Owner) -> Set<Int> {
    let claimed = tiles.filter { owners[$0] != owner }
    for tile in claimed { owners[tile] = owner }
    return claimed
  }

  mutating func remember(_ token: UInt64, tile: Int, issuedBy owner: Owner) {
    let tokens = issued[owner, default: [:]][tile, default: []] + [token]
    issued[owner, default: [:]][tile] = Array(tokens.suffix(Self.rememberedTokens))
  }

  func issued(_ tokens: [UInt64], tile: Int, by owner: Owner) -> [UInt64] {
    let known = Set(issued[owner]?[tile] ?? [])
    return tokens.filter(known.contains)
  }
}
