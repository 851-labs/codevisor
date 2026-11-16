import CodevisorClient
import CodevisorCore
import CoreGraphics
import CodevisorTestSupport
import Foundation
import ScreenSharingV2
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostRequestTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test func stopDuringInitialDisplayLookupPreventsTheStartFromContinuing() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      let lookup = Self.hold(mac)
      let pending = Task { await mac.host.handle(start) }
      await lookup.entered.wait()
      #expect(await mac.host.handle(mac.following(start, .stop)).status == "stopped")
      lookup.release.signal()
      #expect(await pending.value.status == "stopped")
    }
  }

  @Test func aLaterExplicitStartIsNotCancelledByTheEarlierStop() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      let lookup = Self.hold(mac)
      let pending = Task { await mac.host.handle(start) }
      await lookup.entered.wait()
      _ = await mac.host.handle(mac.following(start, .stop))
      lookup.release.signal()
      #expect(await pending.value.status == "stopped")
      #expect(await mac.send(mac.start(as: .macBook, .open)).status == "unavailable")
    }
  }

  @Test func aRepeatedStartFromTheSameAppSupersedesTheOneStillPending() async throws {
    try await Fixture.run { mac in
      let first = await mac.signed(mac.start(as: .macBook, .open))
      let retry = await mac.signed(mac.start(as: .macBook, .open))
      let lookup = Self.hold(mac)
      let pending = Task { await mac.host.handle(first) }
      await lookup.entered.wait()
      let retried = Task { await mac.host.handle(retry) }
      await lookup.entered.wait(for: 2)
      lookup.release.signal()
      #expect(await pending.value.status == "stopped")
      #expect(await retried.value.status == "unavailable")
    }
  }

  @Test func anotherViewersStopDoesNotCancelThePendingStart() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      let lookup = Self.hold(mac)
      let pending = Task { await mac.host.handle(start) }
      await lookup.entered.wait()
      _ = await mac.host.handle(mac.following(start, .stop, viewerId: UUID()))
      lookup.release.signal()
      #expect(await pending.value.status == "unavailable")
    }
  }

  @Test func stoppingOneOfTwoPendingAppsDoesNotCancelTheOther() async throws {
    try await Fixture.run { mac in
      let first = await mac.signed(mac.start(as: .macBook, .open))
      let second = await mac.signed(mac.start(as: .iPhone, .open))
      let lookup = Self.hold(mac)
      let pendingFirst = Task { await mac.host.handle(first) }
      await lookup.entered.wait()
      let pendingSecond = Task { await mac.host.handle(second) }
      await lookup.entered.wait(for: 2)
      _ = await mac.host.handle(mac.following(first, .stop))
      lookup.release.signal()
      #expect(await pendingFirst.value.status == "stopped")
      #expect(await pendingSecond.value.status == "unavailable")
    }
  }

  @Test func shutdownInvalidatesPendingDisplayLookup() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      let lookup = Self.hold(mac)
      let pending = Task { await mac.host.handle(start) }
      await lookup.entered.wait()
      await mac.host.shutdown()
      lookup.release.signal()
      #expect(await pending.value.status == "stopped")
      #expect(await mac.host.handle(start).status == "stopped")
    }
  }

  @Test func aSystemStopInvalidatesEveryPendingOwner() async throws {
    try await Fixture.run { mac in
      let first = await mac.signed(mac.start(as: .macBook, .open))
      let second = await mac.signed(mac.start(as: .iPhone, .open))
      let lookup = Self.hold(mac)
      let pendingFirst = Task { await mac.host.handle(first) }
      await lookup.entered.wait()
      let pendingSecond = Task { await mac.host.handle(second) }
      await lookup.entered.wait(for: 2)
      mac.host.systemStopped(.displayAsleep)
      lookup.release.signal()
      #expect(await pendingFirst.value.status == "stopped")
      #expect(await pendingSecond.value.status == "stopped")
      #expect(await mac.send(mac.start(as: .iPad, .open)).status == "unavailable")
    }
  }

  @Test func onlyAHostWithAMediaEndpointAdvertisesEngineV2() async throws {
    let plain = makeHost(mediaEndpoint: ScreenSharingMediaEndpoint())
    #expect(await plain.handle(capabilities()).engines == nil)
    await plain.shutdown()
    try await Fixture.run { mac in
      #expect(await mac.capabilities(as: .macBook).engines == ["v2"])
    }
  }

  @Test func aHostWhoseMediaEndpointCantBindOffersNoChallengeSoNothingStarts() async {
    let host = makeHost(mediaEndpoint: Self.unboundEndpoint())
    let offered = await host.handle(capabilities())
    #expect(offered.status == "available" && offered.challenge == nil)

    var start = ServerScreenSharingRequest(
      operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: "display")
    start.engine = "v2"
    start.media = .init(endpointId: ServerScreenSharingApp.macBook.key, relayUrl: nil, directAddrs: [])
    start.app = .macBook
    start.intent = .open
    start.proof = .init(nonce: String(repeating: "0", count: 64), signature: String(repeating: "0", count: 128))
    let reply = await host.handle(start)
    #expect(reply.status == "failed" && reply.reason == .proofRejected && reply.media == nil)
    await host.shutdown()
  }

  private final class Lookup {
    let entered = TestSignal()
    let release = TestSignal()
  }

  private static func hold(_ mac: Fixture) -> Lookup {
    let lookup = Lookup()
    mac.listDisplays = {
      lookup.entered.signal()
      await lookup.release.wait()
      return []
    }
    return lookup
  }

  private static func unboundEndpoint() -> ScreenSharingMediaEndpoint {
    let endpoint = ScreenSharingMediaEndpoint()
    endpoint.configure { nil }
    return endpoint
  }

  private func capabilities() -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    request.app = .macBook
    return request
  }

  private func makeHost(mediaEndpoint: ScreenSharingMediaEndpoint) -> ScreenSharingHostService {
    let display = (
      CGMainDisplayID(), ServerScreenSharingDisplay(id: "display", name: "Display", width: 1280, height: 720)
    )
    return ScreenSharingHostService(
      captureAccess: { true }, notificationCenter: NotificationCenter(),
      workspaceNotificationCenter: NotificationCenter(), enumerateDisplays: { [display] }, mediaEndpoint: mediaEndpoint)
  }
}
