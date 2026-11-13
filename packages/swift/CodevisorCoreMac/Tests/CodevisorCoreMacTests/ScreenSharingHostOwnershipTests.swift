import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostOwnershipTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture
  private static let busyMessage = "This Mac is already sharing with another viewer."

  @Test func aStableViewerStillReplacesItsOwnPaneAndIsBusyForAnotherPane() async throws {
    try await Fixture.run { mac in
      let first = mac.stableStart()
      let granted = await mac.send(first)
      #expect(granted.status == "connecting" && granted.media != nil)
      #expect(granted.display == nil && granted.displays.isEmpty)

      let otherPane = await mac.send(mac.stableStart())
      #expect(otherPane.status == "busy" && otherPane.message == Self.busyMessage && otherPane.media == nil)

      let beat = await mac.send(mac.following(first, .heartbeat))
      #expect(beat.status == "connecting" && beat.display == nil && beat.displays.isEmpty)

      let again = await mac.send(mac.stableStart(workspaceId: first.workspaceId, paneId: first.paneId))
      #expect(again.status == "connecting" && again.media?.token != granted.media?.token)
      #expect(await mac.send(mac.following(first, .heartbeat)).status == "stopped")

      let unknownDisplay = await mac.send(
        mac.stableStart(workspaceId: first.workspaceId, paneId: first.paneId, display: "gone"))
      #expect(unknownDisplay.status == "unavailable")
      #expect(unknownDisplay.message == "The selected display is no longer available.")
      #expect(await mac.send(mac.stableStart(display: nil)).status == "failed")
    }
  }

  @Test(arguments: [ServerScreenSharingRequest.Intent.open, .attach])
  func theSameAppStartingAgainReplacesItsOwnSession(_ intent: ServerScreenSharingRequest.Intent) async throws {
    try await Fixture.run { mac in
      let first = await mac.send(mac.start(as: .macBook, .open))
      let again = await mac.send(mac.start(as: .macBook, intent))
      #expect(first.status == "connecting" && again.status == "connecting")
      #expect(again.media != nil && again.media?.token != first.media?.token)
      #expect(again.reason == nil)

      let restart = ServerScreenSharingRequest.restarting(mac.start(as: .macBook, intent))
      #expect(await mac.send(restart).status == "connecting")
    }
  }

  @Test func anOpenFromAnotherAppTakesOverAndTheLoserIsToldWhoHasIt() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      #expect(await mac.send(macBook).status == "connecting")

      let iPhone = await mac.send(mac.start(as: .iPhone, .open))
      #expect(iPhone.status == "connecting" && iPhone.media != nil)

      let lost = await mac.send(mac.following(macBook, .heartbeat))
      #expect(lost.status == "failed" && lost.reason == .takenOver)
      #expect(lost.holderName == "Alexandru's iPhone" && lost.message == "Now viewing on Alexandru's iPhone.")

      let reconnect = await mac.send(mac.start(as: .macBook, .attach))
      #expect(reconnect.status == "busy" && reconnect.reason == .inUse && reconnect.media == nil)
      #expect(reconnect.holderName == "Alexandru's iPhone")
      #expect(await mac.send(mac.following(mac.start(as: .iPhone, .open), .heartbeat)).status == "connecting")

      let viewHere = await mac.send(mac.start(as: .macBook, .open))
      #expect(viewHere.status == "connecting")
    }
  }

  @Test func aPassiveAttachNeverTakesTheSessionFromAnotherApp() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)

      for intent in [ServerScreenSharingRequest.Intent.attach, nil] {
        let refused = await mac.send(mac.start(as: .iPhone, intent))
        #expect(refused.status == "busy" && refused.reason == .inUse)
        #expect(refused.holderName == "Alexandru's MacBook Pro" && refused.message == Self.busyMessage)
      }
      #expect(await mac.send(mac.following(macBook, .heartbeat)).status == "connecting")
    }
  }

  @Test func anAppTakesOverFromAStableViewerWhichCanNeverTakeItBack() async throws {
    try await Fixture.run { mac in
      let stable = mac.stableStart()
      _ = await mac.send(stable)

      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "busy")
      #expect(await mac.send(mac.start(as: .macBook, .open)).status == "connecting")

      let lost = await mac.send(mac.following(stable, .heartbeat))
      #expect(lost.status == "failed" && lost.message == "Now viewing on Alexandru's MacBook Pro.")
      for retry in [stable, ServerScreenSharingRequest.restarting(stable), mac.stableStart()] {
        let refused = await mac.send(retry)
        #expect(["busy", "stopped"].contains(refused.status) && refused.media == nil)
      }
      #expect(await mac.send(mac.following(mac.start(as: .macBook, .open), .heartbeat)).status == "connecting")
    }
  }

  @Test func aTakeoverThatCannotStartLeavesTheHolderAlone() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)

      var wrongKey = mac.start(as: .iPhone, .open)
      wrongKey.media = .init(endpointId: ServerScreenSharingApp.macBook.key, relayUrl: nil, directAddrs: [])
      #expect(await mac.send(wrongKey).status == "failed")

      mac.allowsCapture = false
      let denied = await mac.send(mac.start(as: .iPhone, .open))
      #expect(denied.status == "permission-required" && denied.reason == .permissionMissing)
      mac.allowsCapture = true

      #expect(await mac.send(mac.following(macBook, .heartbeat)).status == "connecting")
    }
  }

  @Test func aStopEndsAnAppsSessionOnlyFromTheAttemptThatStartedIt() async throws {
    try await Fixture.run { mac in
      let first = mac.start(as: .macBook, .open)
      _ = await mac.send(first)
      let second = mac.start(as: .macBook, .attach)
      _ = await mac.send(second)

      #expect(await mac.send(mac.following(first, .stop)).status == "stopped")
      #expect(await mac.send(mac.following(second, .heartbeat, viewerId: UUID())).status == "connecting")

      #expect(await mac.send(mac.following(second, .stop)).status == "stopped")
      let after = await mac.send(mac.following(second, .heartbeat))
      #expect(after.status == "stopped" && after.reason == nil)
    }
  }

  @Test func anAppIsToldWhatItsSessionSharesAndWhichDisplaysExist() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.side, Fixture.main]
      for display in ["gone", nil] {
        let granted = await mac.send(mac.start(as: .macBook, .open, display: display))
        #expect(granted.status == "connecting" && granted.display == Fixture.main)
        #expect(granted.displays == [Fixture.side, Fixture.main])
      }

      let session = try #require(mac.host.current)
      mac.displays = [Fixture.main]
      await mac.host.refreshDisplays(of: session)
      let beat = await mac.send(mac.following(mac.start(as: .macBook, .attach), .heartbeat))
      #expect(beat.status == "connecting" && beat.display == Fixture.main && beat.displays == [Fixture.main])

      mac.displays = []
      let none = await mac.send(mac.start(as: .iPhone, .open))
      #expect(none.status == "unavailable" && none.reason == .noDisplay)
      #expect(await mac.send(mac.following(mac.start(as: .macBook, .attach), .heartbeat)).status == "connecting")
    }
  }

  @Test func everyReplySaysTheHostSupportsAppSessionsAndRefusalsCarryAReason() async throws {
    try await Fixture.run { mac in
      let capabilities = await mac.send(mac.following(mac.stableStart(), .capabilities))
      #expect(capabilities.status == "available" && capabilities.abilities == ["app-sessions"])
      #expect(capabilities.reason == nil)

      mac.allowsCapture = false
      for request in [mac.following(mac.stableStart(), .capabilities), mac.stableStart()] {
        let denied = await mac.send(request)
        #expect(denied.status == "permission-required" && denied.reason == .permissionMissing)
      }

      let newer = try JSONDecoder().decode(
        ServerScreenSharingRequest.self,
        from: Data(
          #"{"version":2,"operation":"capabilities","workspaceId":"\#(UUID())","paneId":"\#(UUID())","viewerId":"\#(UUID())"}"#
            .utf8))
      let outdated = await mac.send(newer)
      #expect(outdated.status == "unavailable" && outdated.reason == .updateNeeded)
      #expect(outdated.message == "Update Codevisor to use Screen Sharing.")
    }
  }

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
}

extension ServerScreenSharingRequest {
  fileprivate static func restarting(_ start: ServerScreenSharingRequest) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .restart, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: start.viewerId,
      displayId: start.displayId)
    request.engine = start.engine
    request.media = start.media
    request.app = start.app
    request.intent = start.intent
    return request
  }
}
