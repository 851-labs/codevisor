struct ScreenSharingV2Recovery {
  private var sentTokens: [Int: [UInt64]] = [:]
  private var acknowledgedTiles: Set<Int> = []
  private var pending: [Int: ScreenSharingTileRefresh] = [:]

  var pendingTiles: Set<Int> { Set(pending.keys) }

  mutating func sent(_ tile: ScreenSharingEncodedTile) {
    if tile.isKeyFrame { forget(tile.tile) }
    guard let sentToken = tile.ltrToken else { return }

    let remembered = sentTokens[tile.tile, default: []] + [sentToken]
    sentTokens[tile.tile] = Array(remembered.suffix(ScreenSharingV2SentTokens.remembered))
  }

  mutating func acknowledged(sentToken: UInt64, tile: Int) -> Bool {
    guard sentTokens[tile]?.contains(sentToken) == true else { return false }

    acknowledgedTiles.insert(tile)
    return true
  }

  mutating func unsent(_ tile: ScreenSharingEncodedTile) {
    if tile.isKeyFrame { forget(tile.tile) }
    lost(tile: tile.tile)
  }

  mutating func lost(tile: Int) {
    retry(acknowledgedTiles.contains(tile) ? .longTermReference : .keyframe, tile: tile)
  }

  mutating func requested(keyframe: Bool, tile: Int) {
    if keyframe { acknowledgedTiles.remove(tile) }
    lost(tile: tile)
  }

  mutating func retry(_ refresh: ScreenSharingTileRefresh, tile: Int) {
    if pending[tile] != .keyframe { pending[tile] = refresh }
  }

  mutating func restore(_ refreshes: [Int: ScreenSharingTileRefresh]) {
    for (tile, refresh) in refreshes { retry(refresh, tile: tile) }
  }

  mutating func takeRefreshes() -> [Int: ScreenSharingTileRefresh] {
    defer { pending = [:] }
    for (tile, refresh) in pending where refresh == .keyframe { forget(tile) }
    return pending
  }

  private mutating func forget(_ tile: Int) {
    sentTokens[tile] = nil
    acknowledgedTiles.remove(tile)
  }
}
