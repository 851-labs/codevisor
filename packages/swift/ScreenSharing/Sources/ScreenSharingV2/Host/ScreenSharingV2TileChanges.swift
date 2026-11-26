struct ScreenSharingV2TileChanges: Equatable, Sendable {
  var changed: Set<Int> = []
  var small: Set<Int> = []
}
