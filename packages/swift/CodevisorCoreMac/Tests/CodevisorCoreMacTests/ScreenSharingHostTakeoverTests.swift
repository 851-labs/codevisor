import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostTakeoverTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test func aRefusedAttachLeavesTheSameAppsPendingOpenAlone() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      await mac.host.end(try #require(mac.host.current), as: .stoppedOnHost)
      let open = await mac.signed(mac.start(as: .macBook, .open))
      let attach = await mac.signed(mac.start(as: .macBook, .attach))
      let entered = TestSignal()
      let release = TestSignal()
      mac.listDisplays = {
        entered.signal()
        await release.wait()
        return [Fixture.main]
      }

      let pending = Task { await mac.send(open) }
      await entered.wait()
      let refused = await mac.send(attach)
      #expect(refused.status == "failed" && refused.reason == .stoppedOnHost)
      release.signal()

      #expect(await pending.value.status == "connecting")
    }
  }

  @Test func whenTwoAppsTakeOverAtOnceTheOldHolderHearsAboutTheOneThatGotTheSession() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)
      let iPhone = await mac.signed(mac.start(as: .iPhone, .open))
      let iPad = await mac.signed(mac.start(as: .iPad, .open))
      let entered = TestSignal()
      let bothChecked = TestSignal()
      let holderEnded = TestSignal()
      var listings = 0
      mac.listDisplays = {
        listings += 1
        let gate = listings <= 2 ? bothChecked : holderEnded
        entered.signal()
        await gate.wait()
        return [Fixture.main]
      }

      let first = Task { await mac.send(iPhone) }
      await entered.wait()
      let second = Task { await mac.send(iPad) }
      await entered.wait(for: 2)
      bothChecked.signal()
      await entered.wait(for: 4)
      #expect(await mac.send(mac.following(iPad, .stop)).status == "stopped")
      holderEnded.signal()

      #expect(await first.value.status == "connecting")
      #expect(await second.value.status == "stopped")
      let displaced = await mac.send(mac.following(macBook, .heartbeat))
      #expect(displaced.status == "failed" && displaced.reason == .takenOver)
      #expect(displaced.holderName == "Alexandru's iPhone")
    }
  }
}
