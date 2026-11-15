import CodevisorClient
import Foundation
import ScreenSharingV2
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostLiveVideoTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test func aSessionCountsAsLiveOnceItSentVideoEvenBeforeItReadsViewing() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      #expect(session.state == "connecting" && session.awaitsLiveVideo)

      session.metrics.increment(ScreenSharingV2Host.sentFramesMetric)

      #expect(session.hasSentVideo && !session.awaitsLiveVideo)
      session.state = "viewing"
      #expect(!session.awaitsLiveVideo)
      session.stopping = true
      #expect(session.awaitsLiveVideo)
    }
  }
}
