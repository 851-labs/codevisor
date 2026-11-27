import Foundation
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingTileMetricsTests {
  @Test(arguments: [
    (ScreenSharingTileRefresh.longTermReference, true, 1),
    (.longTermReference, false, 0),
    (.keyframe, true, 0),
    (nil, true, 0),
  ])
  func onlyAKeyframeAnsweringAnLTRRefreshCountsAsOne(requested: ScreenSharingTileRefresh?, keyframe: Bool, counted: Int)
  {
    let metrics = ScreenSharingMetrics()
    let tile = ScreenSharingEncodedTile(
      tile: 0, update: ScreenSharingTileUpdate(id: 1, tiles: [0]), sourceTimestampNs: 1, capturedNs: 1,
      submittedNs: 1, encodedNs: 2, isKeyFrame: keyframe, refresh: keyframe ? .keyframe : requested, ltrToken: nil,
      accessUnit: ScreenSharingAccessUnit(Data([0, 0, 0, 2, 2, 1])))

    ScreenSharingTileMetrics(metrics).record(tile, requested: requested)

    #expect(metrics.counter("encodedLTRRefreshKeyFrames") == counted)
  }

  @Test(arguments: [
    (false, nil as ScreenSharingTileRefresh?, 1),
    (true, nil, 0),
    (false, .longTermReference, 0),
    (false, .keyframe, 0),
  ])
  func onlyAChangeThatIsNotARefreshIsTimedFromItsCapture(
    refinement: Bool, requested: ScreenSharingTileRefresh?, timed: Int
  ) {
    let metrics = ScreenSharingMetrics()
    let tile = ScreenSharingEncodedTile(
      tile: 0, update: ScreenSharingTileUpdate(id: 1, tiles: [0], isRefinement: refinement), sourceTimestampNs: 1,
      capturedNs: 1_000_000, submittedNs: 3_000_000, encodedNs: 9_000_000, isKeyFrame: false, refresh: requested,
      ltrToken: nil, accessUnit: ScreenSharingAccessUnit(Data([0, 0, 0, 2, 2, 1])))

    ScreenSharingTileMetrics(metrics).record(tile, requested: requested)

    let timing = metrics.snapshot().timings["changeEncoded"]
    #expect((timing?.count ?? 0) == timed)
    #expect(timing.map { $0.maximumMs == 8 } ?? (timed == 0))
  }
}
