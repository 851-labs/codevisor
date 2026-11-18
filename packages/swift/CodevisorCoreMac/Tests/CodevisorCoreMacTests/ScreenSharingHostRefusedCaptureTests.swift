import CodevisorClient
import Foundation
import ScreenCaptureKit
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostRefusedCaptureTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  nonisolated private static func refusedByMacOS() -> NSError {
    NSError(
      domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
  }

  private static func isPermissionRefusal(_ reply: ServerScreenSharingReply) -> Bool {
    reply.reason == .permissionMissing && reply.message == ScreenSharingHostRefusal.permissionMessage
  }

  enum Refused: CaseIterable, Sendable {
    case byScreenCaptureKit, byTheCaptureCheck

    var error: any Error {
      switch self {
      case .byScreenCaptureKit: ScreenSharingHostRefusedCaptureTests.refusedByMacOS()
      case .byTheCaptureCheck: ScreenSharingError.captureNotPermitted
      }
    }
  }

  @Test(arguments: Refused.allCases)
  func whenMacOSRefusesTheDisplayListEveryAskIsAnsweredAsAPermissionRefusal(_ refused: Refused) async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .open))
      mac.listDisplays = { throw refused.error }

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

  private static func captureStops(
    in mac: Fixture, failingItsRestartWith error: any Error
  ) async throws -> ServerScreenSharingReply {
    let start = mac.start(as: .macBook, .open)
    _ = await mac.send(start)
    let session = try #require(mac.host.current)
    session.state = "viewing"
    mac.host.captureRestartDelay = .zero
    mac.failsCaptureOn = ["main"]
    mac.captureFailure = error

    session.capture.onStopped?("Failed during stream due to application connection being interrupted")
    await session.captureTask?.value
    return await mac.send(mac.following(start, .heartbeat))
  }

  @Test func aRestartMacOSRefusesMidSessionEndsTheSessionAsAPermissionRefusal() async throws {
    try await Fixture.run { mac in
      let beat = try await Self.captureStops(in: mac, failingItsRestartWith: Self.refusedByMacOS())

      #expect(beat.status == "failed" && Self.isPermissionRefusal(beat))
      #expect(mac.host.current == nil)
    }
  }

  @Test func aRestartThatFailsForAnotherReasonEndsTheSessionWithTheHostsOwnSentence() async throws {
    try await Fixture.run { mac in
      let beat = try await Self.captureStops(in: mac, failingItsRestartWith: CocoaError(.fileReadUnknown))

      #expect(beat.status == "failed" && beat.reason == nil && mac.host.current == nil)
      #expect(beat.message == "The host Mac's screen capture stopped and couldn't be restarted.")
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
