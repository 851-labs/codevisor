public enum ScreenSharingTileEncoderOutput: Sendable {
  case tile(ScreenSharingEncodedTile)
  case dropped(tile: Int, refresh: ScreenSharingTileRefresh?)
  case unchanged(tile: Int)
  case failed(tile: Int, refresh: ScreenSharingTileRefresh?, message: String)
}
