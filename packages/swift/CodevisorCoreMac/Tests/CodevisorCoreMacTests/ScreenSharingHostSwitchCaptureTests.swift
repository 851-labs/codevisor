import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostSwitchCaptureTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  @Test func whenCaptureFailsOnTheNewDisplayTheSessionGoesBackToTheOldOneAndSaysSo() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      session.state = "viewing"
      mac.failsCaptureOn = ["side"]

      let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(reply.status == "viewing" && reply.reason == .displayUnavailable)
      #expect(reply.message == ScreenSharingHostService.displayNotCaptured && reply.display == Fixture.main)
      #expect(mac.captureStarts == ["side", "main"])
      #expect(mac.host.current === session && session.displayID == Fixture.displayID(of: Fixture.main))
      #expect(session.state == "viewing")

      mac.failsCaptureOn = []
      #expect(await mac.send(mac.heartbeat(as: .macBook, sharing: "side")).display == Fixture.side)
      #expect(mac.captureStarts == ["side", "main", "side"])
    }
  }

  @Test func whenCaptureFailsOnBothDisplaysTheSessionEndsAndSaysWhy() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      mac.host.current?.state = "viewing"
      mac.failsCaptureOn = ["side", "main"]

      let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(reply.status == "failed" && reply.message == ScreenSharingHostService.captureFailed)
      #expect(reply.display == nil && mac.host.current == nil)
      #expect(mac.captureStarts == ["side", "main"])
    }
  }

  @Test func aSwitchBeforeTheFirstFrameStartsNoCaptureAndTheFirstCaptureUsesTheNewDisplay() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      #expect(session.state == "connecting")

      let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(reply.status == "connecting" && reply.reason == nil && reply.display == Fixture.side)
      #expect(mac.captureStarts.isEmpty)
      #expect(session.captureDisplayID == Fixture.displayID(of: Fixture.side))
      try await mac.host.startCapture(session)
      #expect(mac.captureStarts == ["side"])
    }
  }

  @Test func aSwitchThatArrivesAsStopSharingIsClickedIsAnsweredAsStoppedAndMovesNothing() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      session.state = "viewing"

      mac.host.systemStopped(.stoppedOnHost)
      let reply = await mac.send(mac.heartbeat(as: .macBook, sharing: "side"))

      #expect(reply.status == "failed" && reply.reason == .stoppedOnHost && reply.display == nil)
      #expect(mac.captureStarts.isEmpty && session.displayID == Fixture.displayID(of: Fixture.main))
      await session.ending?.value
      #expect(mac.host.current == nil)
    }
  }
}
