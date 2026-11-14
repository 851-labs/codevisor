import CodevisorClient
import CodevisorTestSupport
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
      for bystander in [mac.start(as: .iPad, .attach), mac.stableStart()] {
        let never = await mac.send(mac.following(bystander, .heartbeat))
        #expect(never.status == "stopped" && never.reason == nil && never.holderName == nil)
      }

      let reconnect = await mac.send(mac.start(as: .macBook, .attach))
      #expect(reconnect.status == "busy" && reconnect.reason == .inUse && reconnect.media == nil)
      #expect(reconnect.holderName == "Alexandru's iPhone")
      #expect(await mac.send(mac.heartbeat(as: .iPhone)).status == "connecting")

      let viewHere = await mac.send(mac.start(as: .macBook, .open))
      #expect(viewHere.status == "connecting")
    }
  }

  @Test func aPassiveAttachNeverTakesTheSessionFromAnotherApp() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)

      let refused = await mac.send(mac.start(as: .iPhone, .attach))
      #expect(refused.status == "busy" && refused.reason == .inUse)
      #expect(refused.holderName == "Alexandru's MacBook Pro" && refused.message == Self.busyMessage)
      #expect(await mac.send(mac.start(as: .iPhone, nil)).reason == .proofRejected)
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
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "connecting")
    }
  }

  @Test func aTakeoverThatCannotStartLeavesTheHolderAlone() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)

      var wrongKey = mac.start(as: .iPhone, .open)
      wrongKey.media = .init(endpointId: ServerScreenSharingApp.macBook.key, relayUrl: nil, directAddrs: [])
      #expect(await mac.send(wrongKey).status == "failed")

      var takeovers: [ServerScreenSharingRequest] = []
      for _ in 0..<3 { takeovers.append(await mac.signed(mac.start(as: .iPhone, .open))) }

      mac.allowsCapture = false
      let denied = await mac.send(takeovers[0])
      #expect(denied.status == "permission-required" && denied.reason == .permissionMissing)
      mac.allowsCapture = true

      mac.listDisplays = { throw CocoaError(.fileReadUnknown) }
      #expect(await mac.send(takeovers[1]).status == "failed")
      mac.listDisplays = nil

      mac.media.configure { nil }
      let noEndpoint = await mac.send(takeovers[2])
      #expect(noEndpoint.status == "failed" && noEndpoint.message == ScreenSharingHostService.endpointUnavailable)

      let beat = await mac.send(mac.following(macBook, .heartbeat))
      #expect(beat.status == "connecting" && beat.reason == nil)
    }
  }

  @Test func aTakeoverThatFailsAfterTheHolderEndedLetsTheHolderReconnect() async throws {
    try await Fixture.run { mac in
      let macBook = mac.start(as: .macBook, .open)
      _ = await mac.send(macBook)

      let takeover = await mac.signed(mac.start(as: .iPhone, .open))
      var lookups = 0
      mac.listDisplays = {
        lookups += 1
        guard lookups == 1 else { throw CocoaError(.fileReadUnknown) }
        return [Fixture.main]
      }
      #expect(await mac.send(takeover).status == "failed")
      mac.listDisplays = nil

      let beat = await mac.send(mac.following(macBook, .heartbeat))
      #expect(beat.status == "stopped" && beat.reason == nil && beat.holderName == nil)
      #expect(await mac.send(mac.start(as: .macBook, .attach)).status == "connecting")
    }
  }

  @Test func twoOpensAtTheSameMomentLeaveOneSessionAndTellTheLoserWhoWon() async throws {
    try await Fixture.run { mac in
      let macBook = await mac.signed(mac.start(as: .macBook, .open))
      let iPhone = await mac.signed(mac.start(as: .iPhone, .open))
      let entered = TestSignal()
      let release = TestSignal()
      mac.listDisplays = {
        entered.signal()
        await release.wait()
        return [Fixture.main]
      }
      let first = Task { await mac.send(macBook) }
      await entered.wait()
      let second = Task { await mac.send(iPhone) }
      await entered.wait(for: 2)
      release.signal()

      let replies = [(await first.value, "Alexandru's MacBook Pro"), (await second.value, "Alexandru's iPhone")]
      let winner = try #require(replies.first { $0.0.status == "connecting" })
      let loser = try #require(replies.first { $0.0.status != "connecting" })
      #expect(loser.0.status == "busy" && loser.0.reason == .inUse && loser.0.media == nil)
      #expect(loser.0.holderName == winner.1)
    }
  }

  @Test func aStableRestartResumesOnlyTheSameViewerOnTheSameDisplay() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      let start = mac.stableStart()
      let granted = await mac.send(start)

      let otherViewer = mac.stableStart(workspaceId: start.workspaceId, paneId: start.paneId)
      for refused in [
        ServerScreenSharingRequest.restarting(otherViewer),
        ServerScreenSharingRequest.restarting(start, display: "side"),
        ServerScreenSharingRequest.restarting(mac.stableStart()),
      ] {
        let reply = await mac.send(refused)
        #expect(reply.status == "stopped" && reply.media == nil)
        #expect(reply.message == "The host ended this sharing session. Connect again to start a new one.")
      }

      let resumed = await mac.send(ServerScreenSharingRequest.restarting(start))
      #expect(resumed.status == "connecting" && resumed.media?.token != granted.media?.token)
      #expect(await mac.send(mac.following(start, .heartbeat)).status == "connecting")
    }
  }

  @Test func anAppWaitsForTheRealDisplayWhileTheHostsOwnVirtualOneIsGoingAway() async throws {
    try await Fixture.run { mac in
      let start = await mac.signed(mac.start(as: .macBook, .attach, display: "virtual"))
      var lookups = 0
      mac.listDisplays = {
        lookups += 1
        return lookups == 1 ? [Fixture.hostVirtual] : [Fixture.hostVirtual, Fixture.main]
      }
      let granted = await mac.send(start)
      #expect(granted.status == "connecting" && granted.display == Fixture.main && lookups == 2)
    }
  }

  @Test func aStopEndsAnAppsSessionOnlyWithThatSessionsToken() async throws {
    try await Fixture.run { mac in
      let first = mac.start(as: .macBook, .open)
      _ = await mac.send(first)
      let second = mac.start(as: .macBook, .attach)
      _ = await mac.send(second)

      var junk = mac.following(second, .stop)
      junk.session = String(repeating: "0", count: 64)
      for stale in [mac.following(first, .stop), junk] {
        #expect(await mac.send(stale).status == "stopped")
      }
      #expect(await mac.send(mac.following(second, .heartbeat, viewerId: UUID())).status == "connecting")

      #expect(await mac.send(mac.following(second, .stop)).status == "stopped")
      let after = await mac.send(mac.following(second, .heartbeat))
      #expect(after.status == "stopped" && after.reason == nil)
    }
  }

  @Test func aStopWithoutATokenEndsOnlyTheSessionItsOwnAttemptStarted() async throws {
    try await Fixture.run { mac in
      let start = mac.start(as: .macBook, .open)
      _ = await mac.send(start)

      var otherAttempt = mac.following(start, .stop, viewerId: UUID())
      otherAttempt.session = nil
      #expect(await mac.send(otherAttempt).status == "stopped")
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "connecting")

      var sameAttempt = mac.following(start, .stop)
      sameAttempt.session = nil
      #expect(await mac.send(sameAttempt).status == "stopped")
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "stopped")
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
      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.status == "connecting" && beat.display == Fixture.main && beat.displays == [Fixture.main])

      mac.displays = []
      let none = await mac.send(mac.start(as: .iPhone, .open))
      #expect(none.status == "unavailable" && none.reason == .noDisplay)
      #expect(await mac.send(mac.heartbeat(as: .macBook)).status == "connecting")
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
}
