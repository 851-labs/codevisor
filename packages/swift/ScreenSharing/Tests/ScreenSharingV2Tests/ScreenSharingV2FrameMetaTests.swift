import Foundation
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2FrameMetaTests {
  @Test func roundTripsEveryField() throws {
    let meta = ScreenSharingV2FrameMeta(
      sourceTimestampNs: 5_952_663_675_166, clock: 0xcbf2_9ce4_8422_2325, captureUs: 2886, admissionUs: 75,
      encodeUs: 7315, handOffUs: 41, isRefresh: true)

    #expect(try ScreenSharingV2FrameMeta(meta.data) == meta)
  }

  @Test func refusesAnotherVersion() {
    var data = ScreenSharingV2FrameMeta(
      sourceTimestampNs: 1, clock: 2, captureUs: 3, admissionUs: 4, encodeUs: 5, handOffUs: 6, isRefresh: false
    ).data
    data[0] = 2

    #expect(throws: ScreenSharingV2FrameMetaError.unsupported) { try ScreenSharingV2FrameMeta(data) }
  }
}
