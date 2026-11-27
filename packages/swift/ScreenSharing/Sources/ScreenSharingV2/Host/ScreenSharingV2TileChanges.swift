struct ScreenSharingV2TileChanges: Equatable, Sendable {
  var changed: Set<Int> = []
  var small: Set<Int> = []

  mutating func note(_ extent: ScreenSharingV2TileExtent, of tile: Int) {
    guard extent != .unchanged else { return }

    changed.insert(tile)
    if extent == .small { small.insert(tile) }
  }
}
