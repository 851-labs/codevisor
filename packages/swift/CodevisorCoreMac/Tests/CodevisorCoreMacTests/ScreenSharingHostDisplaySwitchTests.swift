import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostDisplaySwitchTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  private static let other = ServerScreenSharingDisplay(id: "other", name: "Other Display", width: 2560, height: 1440)

  @Test func aHeartbeatNamingAnotherDisplayMovesTheSameSessionThere() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      let granted = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      #expect(granted.display == Fixture.main && granted.abilities?.contains("display-switch") == true)

      let switched = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(switched.status == "connecting" && switched.reason == nil)
      #expect(switched.display == Fixture.side && switched.displays == [Fixture.main, Fixture.side])
      #expect(mac.host.current === session && session.displayID == Fixture.displayID(of: Fixture.side))
      let plain = await mac.send(mac.heartbeat(as: .macBook))
      #expect(plain.status == "connecting" && plain.display == Fixture.side)

      let reconnect = await mac.send(mac.start(as: .macBook, .attach, display: nil))
      #expect(reconnect.display == Fixture.side)
    }
  }

  @Test func namingTheDisplayAlreadySharedDoesNothing() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      var listings = 0
      mac.listDisplays = {
        listings += 1
        return [Fixture.main, Fixture.side]
      }

      for _ in 0..<3 {
        let beat = await mac.send(mac.heartbeat(as: .macBook, sharing: "main"))
        #expect(beat.status == "connecting" && beat.reason == nil && beat.display == Fixture.main)
      }
      #expect(listings == 0 && mac.host.current?.displaySwitch == nil)
    }
  }

  @Test func aDisplayTheHostDoesNotHaveChangesNothingAndSaysSo() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.hostVirtual, Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))

      for missing in ["gone", "virtual"] {
        let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: missing))
        #expect(reply.status == "connecting" && reply.reason == .displayUnavailable)
        #expect(reply.message == ScreenSharingHostService.displayNotConnected && reply.display == Fixture.main)
      }
      let plain = await mac.send(mac.heartbeat(as: .macBook))
      #expect(plain.reason == nil && plain.message == nil && plain.display == Fixture.main)
    }
  }

  @Test func aSwitchThatCannotReadTheDisplayListSaysWhyAndKeepsTheCurrentDisplay() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      mac.listDisplays = { throw CocoaError(.fileReadUnknown) }

      let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(reply.status == "connecting" && reply.reason == .displayUnavailable)
      #expect(reply.message == ScreenSharingHostService.displaysNotListed && reply.display == Fixture.main)
      #expect(session.displayID == Fixture.displayID(of: Fixture.main))
      mac.listDisplays = nil
      let plain = await mac.send(mac.heartbeat(as: .macBook))
      #expect(plain.reason == nil && plain.message == nil && plain.display == Fixture.main)
      #expect(await mac.send(mac.heartbeat(as: .macBook, sharing: "side")).display == Fixture.side)
    }
  }

  @Test func whileASwitchIsUnderWayTheReplySaysSoAndAskingAgainDoesNotRestartIt() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      mac.host.displaySwitchWait = .zero
      let entered = TestSignal()
      let release = TestSignal()
      var listings = 0
      mac.listDisplays = {
        listings += 1
        entered.signal()
        await release.wait()
        return [Fixture.main, Fixture.side]
      }

      for _ in 0..<2 {
        let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))
        #expect(reply.status == "connecting" && reply.reason == .displaySwitching && reply.display == Fixture.main)
      }
      await entered.wait()
      release.signal()
      await session.resizing?.value

      #expect(listings == 2, "one listing for the switch and one to describe the result")
      let done = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))
      #expect(done.reason == nil && done.display == Fixture.side)
    }
  }

  @Test func ofTwoSwitchesInARowTheLastOneAskedForWins() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side, Self.other]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      mac.host.displaySwitchWait = .zero
      let release = TestSignal()
      session.resizing = Task { await release.wait() }
      var listings = 0
      mac.listDisplays = {
        listings += 1
        return [Fixture.main, Fixture.side, Self.other]
      }

      let first = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))
      let second = await mac.send(mac.heartbeat(as: .macBook, sharing: "other"))
      #expect(first.reason == .displaySwitching && second.reason == .displaySwitching)
      #expect(session.display == Fixture.main)
      release.signal()
      await session.resizing?.value

      #expect(listings == 2, "the switch that was overtaken never ran")
      #expect(session.display == Self.other && session.displayID == Fixture.displayID(of: Self.other))
      #expect(session.metrics.snapshot().labels["captureSize"] == "2560 × 1440")
      let overtaken = await mac.send(mac.heartbeat(as: .macBook))
      #expect(overtaken.reason == nil && overtaken.display == Self.other)
    }
  }

  @Test func aSwitchWaitsItsTurnBehindAResizeAndIsDroppedWhenTheViewerAsksForTheCurrentDisplayAgain() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      mac.host.displaySwitchWait = .zero
      let resized = TestSignal()
      session.resizing = Task { await resized.wait() }

      #expect(await mac.send(mac.heartbeat(as: .macBook, sharing: "side")).reason == .displaySwitching)
      #expect(session.displayID == Fixture.displayID(of: Fixture.main), "the resize ahead of it hasn't finished")
      let backToMain = await mac.send(mac.heartbeat(as: .macBook, sharing: "main"))
      #expect(backToMain.reason == nil && backToMain.display == Fixture.main)
      resized.signal()
      await session.resizing?.value

      #expect(session.display == Fixture.main && session.displayID == Fixture.displayID(of: Fixture.main))
    }
  }

  @Test func aSwitchStillWaitingWhenAnotherAppTakesTheSessionIsAnsweredAsTakenOver() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let takeover = await mac.signed(mac.start(as: .iPhone, .open))
      let entered = TestSignal()
      let release = TestSignal()
      var listings = 0
      mac.listDisplays = {
        listings += 1
        guard listings == 1 else { return [Fixture.main, Fixture.side] }

        entered.signal()
        await release.wait()
        return [Fixture.main, Fixture.side]
      }

      let switching = Task { await mac.send(mac.heartbeat(as: .macBook, sharing: "side")) }
      await entered.wait()
      #expect(await mac.send(takeover).status == "connecting")
      release.signal()

      let reply = await switching.value
      #expect(reply.status == "failed" && reply.reason == .takenOver && reply.display == nil)
      #expect(reply.holderName == "Alexandru's iPhone")
      #expect(mac.host.current?.display == Fixture.main, "the new holder's session is untouched")
    }
  }

  @Test func heldKeysAndButtonsAreReleasedOnASwitchAndTheLeaseIsKept() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      var injected: [ScreenSharingInputEvent] = []
      var sent: [ScreenSharingControlMessage] = []
      let control = ScreenSharingHostControl(
        availability: { nil }, inject: { injected.append($0) },
        send: {
          sent.append($0)
          return true
        })
      session.control = control
      control.receive(.request(id: UUID()))
      let lease = try #require(control.lease)
      let point = ScreenSharingPointer(x: 0.25, y: 0.75)
      control.receive(
        .input(lease: lease, sequence: 1, event: .key(code: 0, down: true, repeatKey: false, modifiers: 0)))
      control.receive(
        .input(lease: lease, sequence: 2, event: .button(point, button: 0, down: true, clicks: 1, modifiers: 0)))
      injected = []

      #expect(await mac.send(mac.heartbeat(as: .macBook, sharing: "side")).display == Fixture.side)

      #expect(
        injected == [
          .key(code: 0, down: false, repeatKey: false, modifiers: 0),
          .button(point, button: 0, down: false, clicks: 1, modifiers: 0),
        ])
      #expect(control.lease == lease && control.heldKeys.isEmpty && control.heldButtons.isEmpty)
      #expect(!sent.contains { if case .revoked = $0 { true } else { false } })
    }
  }

  @Test func theHostAnswersADisplaySwitchTheWayTheConnectionCoresFakeHostDoes() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      let fake = FakeHost(abilities: [ServerScreenSharingReply.appSessions, ServerScreenSharingReply.displaySwitch])
      fake.displays = [Fixture.main, Fixture.side]
      var asked = ServerScreenSharingRequest(
        operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
      asked.app = .macBook
      let offered = try await fake.send(asked)
      var start = mac.start(as: .macBook, .open, display: nil)
      let real = [await mac.capabilities(as: .macBook), await mac.send(start)]
      start.proof = .init(nonce: try #require(offered.challenge?.nonce), signature: String(repeating: "0", count: 128))
      let faked = [offered, try await fake.send(start)]
      for (ours, theirs) in zip(real, faked) {
        #expect(ours.abilities == theirs.abilities && ours.displays == theirs.displays)
        #expect(ours.display == theirs.display && ours.reason == theirs.reason)
        #expect(
          (ours.session == nil) == (theirs.session == nil) && (ours.challenge == nil) == (theirs.challenge == nil))
      }

      for wanted in ["side", "side", "gone", nil, "main"] {
        var beat = mac.heartbeat(as: .macBook, sharing: wanted)
        let ours = await mac.send(beat)
        beat.session = faked[1].session
        let theirs = try await fake.send(beat)
        #expect(["connecting", "viewing"].contains(ours.status) && theirs.status == "viewing")
        #expect(ours.reason == theirs.reason && ours.display == theirs.display && ours.displays == theirs.displays)
        #expect(ours.abilities == theirs.abilities)
      }
    }
  }

  @Test func aDisplayOnAHeartbeatWithoutTheSessionsTokenIsIgnored() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      #expect(await mac.send(mac.start(as: .macBook, .open)).status == "connecting")
      var junk = mac.heartbeat(as: .macBook, sharing: "side")
      junk.session = String(repeating: "0", count: 64)
      #expect(await mac.send(junk).status == "stopped")
      var keyOnly = mac.heartbeat(as: .macBook, sharing: "side")
      keyOnly.session = nil
      keyOnly.app = .macBook
      #expect(await mac.send(keyOnly).status == "stopped")
      #expect(mac.host.current?.displayID == Fixture.displayID(of: Fixture.main))
    }
  }
}
