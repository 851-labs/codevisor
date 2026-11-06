import ScreenSharing

struct ScreenSharingTileMetrics {
  private let metrics: ScreenSharingMetrics

  init(_ metrics: ScreenSharingMetrics) {
    self.metrics = metrics
  }

  func record(_ tile: ScreenSharingEncodedTile, requested: ScreenSharingTileRefresh?) {
    metrics.increment("encodedFrames")
    metrics.increment("encodedBytes", by: tile.accessUnit.count)
    if tile.isKeyFrame {
      metrics.increment("encodedKeyFrames")
      metrics.increment("encodedKeyFrameBytes", by: tile.accessUnit.count)
    }
    if tile.refresh == .longTermReference { metrics.increment("encodedLTRRefreshes") }
    if requested == .longTermReference && tile.isKeyFrame { metrics.increment("encodedLTRRefreshKeyFrames") }
    if tile.ltrToken != nil { metrics.increment("encodedLTRFrames") }
    if tile.update.isRefinement { metrics.increment("encodedRefinements") }
    metrics.observe("encode", milliseconds: Double(tile.encodedNs - tile.submittedNs) / 1_000_000)
  }
}
