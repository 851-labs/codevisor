struct ScreenSharingV2TileOwners: Sendable {
  typealias Owner = ScreenSharingV2EncoderRoute.Choice

  private var owners: [Int: Owner]
  private var issued: [Owner: ScreenSharingIssuedTokens] = [:]

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
    issued[owner, default: ScreenSharingIssuedTokens()].remember(token, tile: tile)
  }

  func acknowledgements(of tokens: [UInt64], tile: Int) -> [(owner: Owner, tokens: [UInt64])] {
    let current = owners[tile] ?? .slow
    let other: Owner = current == .fast ? .slow : .fast
    let currents = issued(tokens, tile: tile, by: current)
    let rest = tokens.filter { !currents.contains($0) }
    return [(current, currents), (other, issued(rest, tile: tile, by: other))]
  }

  private func issued(_ tokens: [UInt64], tile: Int, by owner: Owner) -> [UInt64] {
    issued[owner]?.issued(tokens, tile: tile) ?? []
  }
}
