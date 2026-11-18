import CodevisorClient
import Foundation
import ScreenCaptureKit
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostRefusedCaptureTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  private static func refusedByMacOS() -> NSError {
    NSError(
      domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
  }

  private static func isPermissionRefusal(_ reply: ServerScreenSharingReply) -> Bool {
    reply.reason == .permissionMissing && reply.message == ScreenSharingHostRefusal.permissionMessage
  }

  @Test func whenMacOSRefusesTheDisplayListEveryAskIsAnsweredAsAPermissionRefusal() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      mac.listDisplays = { throw Self.refusedByMacOS() }

      let asked = await mac.capabilities(as: .macBook)
      #expect(asked.status == "permission-required" && Self.isPermissionRefusal(asked))
      let started = await mac.send(start)
      #expect(started.status == "permission-required" && Self.isPermissionRefusal(started))
      #expect(mac.host.current == nil)
    }
  }

  @Test func aTakeoverMacOSRefusesIsAnsweredAsAPermissionRefusal() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      let takeover = await mac.signed(mac.start(as: .iPhone, .open))
      mac.listDisplays = { throw Self.refusedByMacOS() }

      let refused = await mac.send(takeover)

      #expect(refused.status == "permission-required" && Self.isPermissionRefusal(refused))
    }
  }

  @Test func anyOtherListingFailureSendsNoneOfTheSystemsTextButKeepsTheHostsOwnSentence() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      mac.listDisplays = { throw CocoaError(.fileReadUnknown) }

      let asked = await mac.capabilities(as: .macBook)
      #expect(asked.status == "unavailable" && asked.reason == nil && asked.message == nil)
      let started = await mac.send(start)
      #expect(started.status == "failed" && started.reason == nil && started.message == nil)

      mac.listDisplays = { throw ScreenSharingCaptureStallRecovery.stuck }
      let stuck = await mac.capabilities(as: .macBook)
      #expect(stuck.message == "The host Mac's screen capture isn't responding. Try again in a minute.")
    }
  }

  @Test func aCaptureStartMacOSRefusesEndsTheSessionAsAPermissionRefusalAndALaterAttachMayTryAgain() async throws {
    try await Fixture.run { mac in
      let start = mac.start(as: .macBook, .open)
      _ = await mac.send(start)
      let session = try #require(mac.host.current)
      mac.failsCaptureOn = ["main"]
      mac.captureFailure = Self.refusedByMacOS()

      session.peer.onConnectionChanged?("connected")
      await session.captureTask?.value

      let beat = await mac.send(mac.following(start, .heartbeat))
      #expect(beat.status == "failed" && Self.isPermissionRefusal(beat))
      mac.failsCaptureOn = []
      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "connecting")
    }
  }

  @Test func theSystemsTextForAStoppedCaptureIsNeverSentInAHeartbeat() async throws {
    try await Fixture.run { mac in
      let start = mac.start(as: .macBook, .open)
      _ = await mac.send(start)
      let session = try #require(mac.host.current)

      session.metrics.label("captureError", "Stream was stopped by the system")
      let beat = await mac.send(mac.following(start, .heartbeat))

      #expect(beat.status == "connecting" && beat.message == nil && mac.host.current === session)
    }
  }
}
