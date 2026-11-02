import ScreenSharing

enum ScreenSharingV2HostTiming {
  static func meta(
    for tile: ScreenSharingEncodedTile, layout: ScreenSharingV2TileLayout, sendingNs: Int64
  ) -> ScreenSharingV2FrameMeta {
    ScreenSharingV2FrameMeta(
      sourceTimestampNs: tile.sourceTimestampNs, clock: ScreenSharingClockIdentity.current,
      captureUs: microseconds(from: tile.sourceTimestampNs, to: tile.capturedNs),
      admissionUs: microseconds(from: tile.capturedNs, to: tile.submittedNs),
      encodeUs: microseconds(from: tile.submittedNs, to: tile.encodedNs),
      handOffUs: microseconds(from: tile.encodedNs, to: sendingNs), isRefresh: tile.recovers, update: tile.update,
      layout: layout)
  }

  private static func microseconds(from start: Int64, to end: Int64) -> UInt32 {
    UInt32(clamping: max(0, end - start) / 1000)
  }
}
