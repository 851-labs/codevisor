import Foundation
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2RecoveryTests {
  @Test func onlyTheNewestFramesOfATileCanStillBeAcknowledged() {
    var recovery = ScreenSharingV2Recovery()
    recovery.sent(Self.tile(keyframe: true, sentToken: 1))

    for sentToken in 2...UInt64(ScreenSharingV2SentTokens.remembered + 1) {
      recovery.sent(Self.tile(keyframe: false, sentToken: sentToken))
    }

    let acknowledged = [1, 2].map { recovery.acknowledged(sentToken: $0, tile: 0) }

    #expect(acknowledged == [false, true])
  }

  @Test func aKeyframeThatFailedToSendStillEndsTheFramesBeforeIt() {
    var recovery = ScreenSharingV2Recovery()
    recovery.sent(Self.tile(keyframe: true, sentToken: 1))
    recovery.sent(Self.tile(keyframe: false, sentToken: 2))

    recovery.unsent(Self.tile(keyframe: true, sentToken: 3))

    let acknowledged = recovery.acknowledged(sentToken: 2, tile: 0)
    let refreshes = recovery.takeRefreshes()

    #expect(!acknowledged)
    #expect(refreshes == [0: .keyframe])
  }

  private static func tile(keyframe: Bool, sentToken: UInt64) -> ScreenSharingEncodedTile {
    ScreenSharingEncodedTile(
      tile: 0, update: ScreenSharingTileUpdate(id: 1, tiles: [0]), sourceTimestampNs: 0, capturedNs: 0,
      submittedNs: 0, encodedNs: 0, isKeyFrame: keyframe, refresh: nil, ltrToken: sentToken,
      accessUnit: ScreenSharingAccessUnit(Data()))
  }
}
