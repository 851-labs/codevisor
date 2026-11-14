import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostProofTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test func aChallengeIsHandedOnlyToACapabilitiesRequestThatNamesAnApp() async throws {
    try await Fixture.run { mac in
      let anonymous = await mac.send(mac.following(mac.stableStart(), .capabilities))
      #expect(anonymous.status == "available" && anonymous.challenge == nil)

      let first = try #require(await mac.challenge())
      let second = try #require(await mac.challenge())
      #expect(first.hostKey == second.hostKey && first.hostKey.count == 64)
      #expect(first.nonce != second.nonce && first.nonce.count == 64)
    }
  }

  @Test func aStartWhoseKeyIsNotProvenIsRejectedWithAFreshChallengeAndLeavesTheHolderAlone() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))

      var unsigned = mac.start(as: .iPhone, .open)
      unsigned.proof = .init(nonce: String(repeating: "0", count: 64), signature: String(repeating: "0", count: 128))
      var forged = mac.start(as: .macBook, .open)
      forged.proof = try ServerScreenSharingProof(
        of: forged, answering: try #require(await mac.challenge()), signer: ServerScreenSharingApp.iPhone.signer)
      var missing = mac.start(as: .macBook, .attach)
      missing.proof = .init(nonce: "", signature: "")

      for request in [unsigned, forged, missing, mac.start(as: .iPhone, .open)] {
        let reply = await mac.host.handle(request)
        #expect(reply.status == "failed" && reply.reason == .proofRejected)
        #expect(reply.media == nil && reply.session == nil && reply.holderName == nil)
        #expect(reply.challenge?.nonce.count == 64)
      }
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "connecting")
    }
  }

  @Test func aSignedStartWorksOnceAndOnlyForTheRequestThatWasSigned() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .attach))
      #expect(await mac.send(start).status == "connecting")
      #expect(await mac.send(start).reason == .proofRejected)

      let attach = await mac.signed(mac.start(as: .iPhone, .attach))
      var open = attach
      open.intent = .open
      #expect(await mac.send(open).reason == .proofRejected)
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "connecting")
    }
  }

  @Test func aRejectedStartDoesNotCancelTheSameKeysPendingStart() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      var forged = mac.start(as: .macBook, .open)
      forged.proof = .init(nonce: String(repeating: "0", count: 64), signature: String(repeating: "0", count: 128))
      let entered = TestSignal()
      let release = TestSignal()
      mac.listDisplays = {
        entered.signal()
        await release.wait()
        return [Fixture.main]
      }

      let pending = Task { await mac.send(start) }
      await entered.wait()
      mac.listDisplays = nil
      #expect(await mac.send(forged).reason == .proofRejected)
      release.signal()

      #expect(await pending.value.status == "connecting")
    }
  }

  @Test func aGrantedStartReturnsATokenAndAHeartbeatIsMatchedByTokenAlone() async throws {
    try await Fixture.run { mac in
      let start = mac.start(as: .macBook, .open)
      let granted = await mac.send(start)
      let token = try #require(granted.session)
      #expect(token.count == 64 && token != granted.media?.token)

      var byKeyOnly = mac.following(start, .heartbeat)
      byKeyOnly.session = nil
      byKeyOnly.app = .macBook
      var junk = mac.following(start, .heartbeat)
      junk.session = String(repeating: "0", count: 64)
      for request in [byKeyOnly, junk] {
        let reply = await mac.send(request)
        #expect(reply.status == "stopped" && reply.display == nil && reply.displays.isEmpty)
      }

      let beat = await mac.send(mac.following(start, .heartbeat))
      #expect(beat.status == "connecting" && beat.display == Fixture.main && beat.session == nil)
    }
  }

  @Test func aTokenNeverKeepsAStableViewersSessionAlive() async throws {
    try await Fixture.run { mac in
      let stable = mac.stableStart()
      let granted = await mac.send(stable)
      #expect(granted.status == "connecting" && granted.session == nil)

      var withToken = mac.following(stable, .heartbeat)
      withToken.session = String(repeating: "0", count: 64)
      #expect(await mac.send(withToken).status == "stopped")
      var stop = mac.following(stable, .stop)
      stop.session = String(repeating: "0", count: 64)
      #expect(await mac.send(stop).status == "stopped")

      #expect(await mac.send(mac.following(stable, .heartbeat)).status == "connecting")
    }
  }

  @Test func theHostRemembersWhyTheLastSixteenSessionsEndedAndNoMore() async throws {
    try await Fixture.run { mac in
      var starts: [ServerScreenSharingRequest] = []
      for _ in 0...ScreenSharingHostService.rememberedEndedSessions {
        starts.append(mac.start(as: .macBook, .open))
        _ = await mac.send(starts[starts.count - 1])
      }
      await mac.host.end(try #require(mac.host.current), as: .stoppedOnHost)

      let forgotten = await mac.send(mac.following(starts[0], .heartbeat))
      #expect(forgotten.status == "stopped" && forgotten.reason == nil)
      for remembered in [starts[1], starts[starts.count - 1]] {
        let reply = await mac.send(mac.following(remembered, .heartbeat))
        #expect(reply.status == "failed" && reply.reason == .stoppedOnHost)
      }
    }
  }

  @Test func challengesExpireWorkOnceAndTheOldestGiveWayPastTheLimit() {
    var challenges = ScreenSharingHostChallenges()
    let hostKey = String(repeating: "a", count: 64)

    let used = challenges.mint(hostKey: hostKey, now: 0)
    #expect(challenges.redeem(used.nonce.uppercased(), now: 1) == hostKey)
    #expect(challenges.redeem(used.nonce, now: 2) == nil)

    let late = challenges.mint(hostKey: hostKey, now: 0)
    #expect(challenges.redeem(late.nonce, now: ScreenSharingHostChallenges.lifetime) == nil)
    let inTime = challenges.mint(hostKey: hostKey, now: 0)
    #expect(challenges.redeem(inTime.nonce, now: ScreenSharingHostChallenges.lifetime - 1) == hostKey)

    let oldest = challenges.mint(hostKey: hostKey, now: 10)
    let kept = (0..<ScreenSharingHostChallenges.limit).map { _ in challenges.mint(hostKey: hostKey, now: 10) }
    #expect(challenges.redeem(oldest.nonce, now: 11) == nil)
    #expect(challenges.redeem(kept[0].nonce, now: 11) == hostKey)
    #expect(challenges.redeem(kept[kept.count - 1].nonce, now: 11) == hostKey)
  }
}
