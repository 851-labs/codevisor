public struct ScreenSharingTileUpdate: Equatable, Sendable {
  public let id: UInt32
  public let tiles: Set<Int>
  public let isRefinement: Bool
  public let repeatsCapture: Bool

  public init(id: UInt32, tiles: Set<Int>, isRefinement: Bool = false, repeatsCapture: Bool = false) {
    self.id = id
    self.tiles = tiles
    self.isRefinement = isRefinement
    self.repeatsCapture = repeatsCapture
  }
}
