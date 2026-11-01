public enum ScreenSharingTileEncoderOutput: Sendable {
  case tile(ScreenSharingEncodedTile)
  case dropped(tile: Int, refresh: ScreenSharingTileRefresh?)
  case failed(tile: Int, refresh: ScreenSharingTileRefresh?, message: String)
}
