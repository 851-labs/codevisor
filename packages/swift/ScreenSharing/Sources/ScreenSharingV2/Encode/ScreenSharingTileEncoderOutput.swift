public enum ScreenSharingTileEncoderOutput: Sendable {
  case tile(ScreenSharingEncodedTile)
  case dropped(tile: Int, refresh: ScreenSharingTileRefresh?)
  case unchanged(tile: Int, update: UInt32)
  case failed(tile: Int, refresh: ScreenSharingTileRefresh?, message: String)
}
