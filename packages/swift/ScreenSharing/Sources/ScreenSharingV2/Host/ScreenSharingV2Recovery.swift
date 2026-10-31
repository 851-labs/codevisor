struct ScreenSharingV2Recovery {
  private var issuedTokens: [Int: Set<UInt64>] = [:]
  private var acknowledgedTiles: Set<Int> = []
  private var pending: [Int: ScreenSharingTileRefresh] = [:]

  var isPending: Bool { !pending.isEmpty }

  mutating func sent(_ tile: ScreenSharingEncodedTile) {
    if tile.isKeyFrame {
      issuedTokens[tile.tile] = []
      acknowledgedTiles.remove(tile.tile)
    }
    if let token = tile.ltrToken { issuedTokens[tile.tile, default: []].insert(token) }
  }

  mutating func acknowledged(token: UInt64, tile: Int) -> Bool {
    guard issuedTokens[tile]?.contains(token) == true else { return false }

    acknowledgedTiles.insert(tile)
    return true
  }

  mutating func lost(tile: Int) {
    retry(acknowledgedTiles.contains(tile) ? .longTermReference : .keyframe, tile: tile)
  }

  mutating func retry(_ refresh: ScreenSharingTileRefresh, tile: Int) {
    if pending[tile] != .keyframe { pending[tile] = refresh }
  }

  mutating func restore(_ refreshes: [Int: ScreenSharingTileRefresh]) {
    for (tile, refresh) in refreshes { retry(refresh, tile: tile) }
  }

  mutating func takeRefreshes() -> [Int: ScreenSharingTileRefresh] {
    defer { pending = [:] }
    return pending
  }
}
