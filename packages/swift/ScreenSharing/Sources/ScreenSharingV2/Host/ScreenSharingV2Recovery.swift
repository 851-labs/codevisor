struct ScreenSharingV2Recovery {
  private var acknowledgedTiles: Set<Int> = []
  private var pending: [Int: ScreenSharingTileRefresh] = [:]

  var isPending: Bool { !pending.isEmpty }

  mutating func acknowledged(tile: Int) {
    acknowledgedTiles.insert(tile)
  }

  mutating func lost(tile: Int) {
    let refresh: ScreenSharingTileRefresh = acknowledgedTiles.contains(tile) ? .longTermReference : .keyframe
    if pending[tile] != .keyframe { pending[tile] = refresh }
  }

  mutating func takeRefreshes() -> [Int: ScreenSharingTileRefresh] {
    defer { pending = [:] }
    return pending
  }
}
