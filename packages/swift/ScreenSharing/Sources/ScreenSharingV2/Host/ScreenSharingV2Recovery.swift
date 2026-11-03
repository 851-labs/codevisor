struct ScreenSharingV2Recovery {
  static let failedRefreshesBeforeKeyframe = 2

  private var issuedTokens: [Int: Set<UInt64>] = [:]
  private var acknowledgedTiles: Set<Int> = []
  private var pending: [Int: ScreenSharingTileRefresh] = [:]
  private var refreshFrames: [Int: UInt32] = [:]
  private var failedRefreshes: [Int: Int] = [:]

  var pendingTiles: Set<Int> { Set(pending.keys) }

  mutating func sent(_ tile: ScreenSharingEncodedTile, frame: UInt32) {
    if tile.isKeyFrame {
      issuedTokens[tile.tile] = []
      acknowledgedTiles.remove(tile.tile)
      refreshFrames[tile.tile] = nil
      failedRefreshes[tile.tile] = nil
    } else if tile.refresh == .longTermReference {
      refreshFrames[tile.tile] = frame
    }
    if let token = tile.ltrToken { issuedTokens[tile.tile, default: []].insert(token) }
  }

  mutating func acknowledged(token: UInt64, tile: Int) -> Bool {
    guard issuedTokens[tile]?.contains(token) == true else { return false }

    acknowledgedTiles.insert(tile)
    return true
  }

  mutating func delivered(frame: UInt32, tile: Int) {
    guard refreshFrames[tile] == frame else { return }

    refreshFrames[tile] = nil
    failedRefreshes[tile] = nil
  }

  mutating func unsent(_ tile: ScreenSharingEncodedTile) {
    if tile.isKeyFrame { acknowledgedTiles.remove(tile.tile) }
    retry(refresh(for: tile.tile), tile: tile.tile)
  }

  mutating func lost(frame: UInt32, tile: Int) {
    if refreshFrames[tile] == frame {
      refreshFrames[tile] = nil
      failedRefreshes[tile, default: 0] += 1
    }
    retry(refresh(for: tile), tile: tile)
  }

  mutating func requested(keyframe: Bool, tile: Int) {
    if keyframe { acknowledgedTiles.remove(tile) }
    retry(refresh(for: tile), tile: tile)
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

  private func refresh(for tile: Int) -> ScreenSharingTileRefresh {
    let exhausted = failedRefreshes[tile, default: 0] >= Self.failedRefreshesBeforeKeyframe
    return acknowledgedTiles.contains(tile) && !exhausted ? .longTermReference : .keyframe
  }
}
