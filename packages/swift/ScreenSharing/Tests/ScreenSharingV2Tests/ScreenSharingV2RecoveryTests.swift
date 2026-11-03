import Foundation
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2RecoveryTests {
  private static func tile(
    refresh: ScreenSharingTileRefresh?, keyframe: Bool = false, token: UInt64? = nil
  )
    -> ScreenSharingEncodedTile
  {
    ScreenSharingEncodedTile(
      tile: 0, update: ScreenSharingTileUpdate(id: 1, tiles: [0]), sourceTimestampNs: 0, capturedNs: 0,
      submittedNs: 0, encodedNs: 0, isKeyFrame: keyframe, refresh: refresh, ltrToken: token,
      accessUnit: ScreenSharingAccessUnit(Data([0, 0, 0, 2, 2, 1])))
  }

  @Test func aRefreshAcknowledgedBeforeItsSendWasRecordedStillStartsTheCountOver() {
    var recovery = ScreenSharingV2Recovery()
    recovery.sent(Self.tile(refresh: .keyframe, keyframe: true, token: 7), frame: 0)
    _ = recovery.acknowledged(token: 7, tile: 0)
    recovery.sent(Self.tile(refresh: .longTermReference), frame: 1)
    recovery.lost(frame: 1, tile: 0)
    recovery.delivered(frame: 2, tile: 0)
    recovery.sent(Self.tile(refresh: .longTermReference), frame: 2)
    recovery.sent(Self.tile(refresh: .longTermReference), frame: 3)
    _ = recovery.takeRefreshes()

    recovery.lost(frame: 3, tile: 0)

    #expect(recovery.takeRefreshes() == [0: .longTermReference])
  }
}
