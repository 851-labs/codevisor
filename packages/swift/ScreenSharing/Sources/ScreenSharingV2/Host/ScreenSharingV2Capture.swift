import ScreenSharing

struct ScreenSharingV2Capture: Sendable {
  let frame: ScreenSharingVideoFrame
  let capturedNs: Int64

  func request(refreshes: [Int: ScreenSharingTileRefresh]) -> ScreenSharingTileEncodeRequest {
    ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: frame.timestampNs, capturedNs: capturedNs,
      refreshes: refreshes)
  }
}
