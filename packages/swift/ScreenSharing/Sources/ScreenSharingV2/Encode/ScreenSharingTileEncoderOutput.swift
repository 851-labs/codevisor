public enum ScreenSharingTileEncoderOutput: Sendable {
  case tile(ScreenSharingEncodedTile)
  case dropped(sourceTimestampNs: Int64)
  case failed(String)
}
