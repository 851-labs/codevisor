import Foundation
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2FrameMetaTests {
  private static func meta(update: ScreenSharingTileUpdate) -> ScreenSharingV2FrameMeta {
    ScreenSharingV2FrameMeta(
      sourceTimestampNs: 5_952_663_675_166, clock: 0xcbf2_9ce4_8422_2325, captureUs: 2886, admissionUs: 75,
      encodeUs: 7315, handOffUs: 41, isRefresh: true, update: update,
      layout: ScreenSharingV2TileLayout(width: 3840, height: 2160, count: 4, tileHeight: 576))
  }

  @Test(arguments: [false, true])
  func roundTripsEveryField(isRefinement: Bool) throws {
    let meta = Self.meta(
      update: ScreenSharingTileUpdate(id: 0xdead_beef, tiles: [0, 2, 3], isRefinement: isRefinement))

    #expect(try ScreenSharingV2FrameMeta(meta.data) == meta)
  }

  @Test func refusesAnotherVersion() {
    var data = Self.meta(update: ScreenSharingTileUpdate(id: 1, tiles: [0])).data
    data[0] = 1

    #expect(throws: ScreenSharingV2FrameMetaError.unsupported) { try ScreenSharingV2FrameMeta(data) }
  }
}
