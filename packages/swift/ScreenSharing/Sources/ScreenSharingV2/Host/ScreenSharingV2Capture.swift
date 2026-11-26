import ScreenSharing

struct ScreenSharingV2Capture: Sendable {
  let frame: ScreenSharingVideoFrame
  let capturedNs: Int64

  func request(
    update: ScreenSharingTileUpdate, refreshes: [Int: ScreenSharingTileRefresh], smallTiles: Set<Int>
  ) -> ScreenSharingTileEncodeRequest {
    ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: frame.timestampNs, capturedNs: capturedNs, update: update,
      refreshes: refreshes, smallTiles: smallTiles)
  }
}
