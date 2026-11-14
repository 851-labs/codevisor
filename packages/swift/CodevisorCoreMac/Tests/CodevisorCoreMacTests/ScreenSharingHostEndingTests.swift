import AppKit
import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostEndingTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test(arguments: [
    (ScreenSharingHostEnding.stoppedOnHost, ServerScreenSharingReason.stoppedOnHost),
    (.displayAsleep, .displayAsleep), (.sessionSwitched, .sessionSwitched), (.displayGone, .noDisplay),
  ])
  func aSessionEndedOnTheHostTellsItsOwnerWhyInTodaysWords(
    _ ending: ScreenSharingHostEnding, _ reason: ServerScreenSharingReason
  ) async throws {
    try await Fixture.run { mac in
      for start in [mac.start(as: .macBook, .open), mac.stableStart()] {
        _ = await mac.send(start)
        await mac.host.end(try #require(mac.host.current), as: ending)
        let beat = await mac.send(mac.following(start, .heartbeat))
        #expect(beat.status == "failed" && beat.reason == reason)
        #expect(beat.message == "Screen sharing was stopped on the host Mac.")
        #expect(beat.holderName == nil)
      }
    }
  }

  @Test(arguments: [
    (ScreenSharingHostEnding.stoppedOnHost, ServerScreenSharingReason.stoppedOnHost),
    (.displayAsleep, .displayAsleep), (.sessionSwitched, .sessionSwitched),
  ])
  func anAutomaticReconnectCannotUndoAnEndingOnTheHostButAnOpenCan(
    _ ending: ScreenSharingHostEnding, _ reason: ServerScreenSharingReason
  ) async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      await mac.host.end(try #require(mac.host.current), as: ending)

      for reconnect in [mac.start(as: .macBook, .attach), .restarting(mac.start(as: .macBook, .attach))] {
        let refused = await mac.send(reconnect)
        #expect(refused.status == "failed" && refused.reason == reason && refused.media == nil)
        #expect(refused.message == "Screen sharing was stopped on the host Mac.")
      }
      #expect(mac.host.current == nil)

      #expect(await mac.send(mac.start(as: .macBook, .open)).status == "connecting")
      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "connecting")
    }
  }

  @Test func anotherAppsSessionLetsTheStoppedAppAttachAgainLater() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      await mac.host.end(try #require(mac.host.current), as: .stoppedOnHost)

      let iPhone = mac.start(as: .iPhone, .attach)
      #expect(await mac.send(iPhone).status == "connecting")
      #expect(await mac.send(mac.following(iPhone, .stop)).status == "stopped")

      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "connecting")
    }
  }

  @Test func aDisplayThatWentAwayDoesNotHoldBackAReconnect() async throws {
    try await Fixture.run { mac in
      _ = await mac.send(mac.start(as: .macBook, .open))
      await mac.host.end(try #require(mac.host.current), as: .displayGone)

      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "connecting")
    }
  }

  @Test(arguments: [
    (NSWorkspace.screensDidSleepNotification, ServerScreenSharingReason.displayAsleep),
    (NSWorkspace.sessionDidResignActiveNotification, .sessionSwitched),
  ])
  func theHostsDisplaySleepingOrItsUserSwitchingEndsTheSessionWithThatReason(
    _ notification: Notification.Name, _ reason: ServerScreenSharingReason
  ) async throws {
    try await Fixture.run { mac in
      let start = mac.start(as: .macBook, .open)
      _ = await mac.send(start)
      let session = try #require(mac.host.current)

      mac.workspace.post(name: notification, object: nil)
      await mac.host.end(session)

      #expect(mac.host.current == nil)
      #expect(await mac.send(mac.following(start, .heartbeat)).reason == reason)
      #expect(await mac.send(mac.start(as: .macBook, .attach)).reason == reason)
    }
  }
}

extension ServerScreenSharingRequest {
  static func restarting(_ start: ServerScreenSharingRequest, display: String? = nil) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .restart, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: start.viewerId,
      displayId: display ?? start.displayId)
    request.engine = start.engine
    request.media = start.media
    request.app = start.app
    request.intent = start.intent
    return request
  }
}
