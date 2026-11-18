import CodevisorClient
import CoreGraphics
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("A shared display that goes away", .timeLimit(.minutes(1)))
struct ScreenSharingHostDisplayFollowTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  private static let wide = ServerScreenSharingDisplay(id: "other", name: "Wide Display", width: 3440, height: 1440)
  private static let gone = "Failed to find any displays or windows to capture"

  private func viewing(_ mac: Fixture) async throws -> ScreenSharingHostSession {
    mac.displays = [Fixture.main, Self.wide]
    _ = await mac.send(mac.start(as: .macBook, .open, display: Self.wide.id))
    let session = try #require(mac.host.current)
    session.state = "viewing"
    #expect(session.configuration.width == 3440 && session.configuration.height == 1440)
    return session
  }

  private func expectMovedToMain(_ session: ScreenSharingHostSession, on mac: Fixture) async {
    let beat = await mac.send(mac.heartbeat(as: .macBook))
    #expect(beat.status == "viewing" && beat.display == Fixture.main && beat.displays == [Fixture.main])
    #expect(mac.host.current === session && session.displayID == Fixture.displayID(of: Fixture.main))
    #expect(session.configuration.width == 1280 && session.configuration.height == 720, "the stream's size")
    #expect(session.capturing?.configuration == session.configuration, "the capture's size")
    #expect(mac.captureStarts == ["main"])
    #expect(session.metrics.counter("captureRestarts") == 0 && session.notice == nil, "not a capture failure")
  }

  @Test func whenTheScreensChangeTheSessionMovesToTheRemainingDisplayAtThatDisplaysOwnSize() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)

      mac.displays = [Fixture.main]
      mac.host.screenParametersChanged()
      await session.resizing?.value

      await expectMovedToMain(session, on: mac)
    }
  }

  @Test func whenTheCaptureStopsFirstTheSessionStillMovesAndIsNotTreatedAsACaptureFailure() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)

      mac.displays = [Fixture.main]
      session.capture.onStopped?(Self.gone)
      #expect(session.state == "viewing", "control and the session are kept")
      mac.host.screenParametersChanged()
      await session.resizing?.value

      await expectMovedToMain(session, on: mac)
    }
  }

  @Test func beforeTheFirstFrameTheSessionMovesWithoutStartingACapture() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Self.wide]
      _ = await mac.send(mac.start(as: .macBook, .open, display: Self.wide.id))
      let session = try #require(mac.host.current)

      mac.displays = [Fixture.main]
      mac.host.screenParametersChanged()
      await session.resizing?.value

      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.status == "connecting" && beat.display == Fixture.main)
      #expect(session.configuration.width == 1280 && session.configuration.height == 720)
      #expect(mac.captureStarts.isEmpty)
    }
  }

  @Test func whenNoDisplayIsLeftTheSessionEndsSayingThereIsNoDisplay() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)

      mac.displays = []
      mac.host.screenParametersChanged()
      await mac.host.end(session)

      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.reason == .noDisplay && mac.captureStarts.isEmpty)
    }
  }

  @Test func whenTheRemainingDisplayCannotBeCapturedTheSessionEndsAndSaysWhy() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      mac.failsCaptureOn = ["main"]

      mac.displays = [Fixture.main]
      mac.host.screenParametersChanged()
      await session.resizing?.value
      await mac.host.end(session)

      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.status == "failed" && beat.message == "Capture refused." && mac.captureStarts == ["main"])
    }
  }

  @Test func anIdenticalMonitorOfAnotherShapeIsMovedToAndNotTakenForTheSameDisplay() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let twin = ScreenSharingDisplayIdentity.Online(
        id: Fixture.displayID(of: Fixture.main), identity: session.displayIdentity, isMain: true, isVirtual: false,
        pixels: .init(width: 1280, height: 720))
      mac.displays = [Fixture.main]
      mac.host.onlineDisplays = { [twin] }

      mac.host.screenParametersChanged()
      await session.resizing?.value

      await expectMovedToMain(session, on: mac)
    }
  }

  @Test func theSameDisplayUnderANewNumberKeepsItsStreamAndStartsNoCapture() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let renumbered = CGMainDisplayID() &+ 9
      let identity = session.displayIdentity
      let pixels = ScreenSharingDisplayIdentity.Pixels(width: 3440, height: 1440)
      mac.host.onlineDisplays = {
        [.init(id: renumbered, identity: identity, isMain: false, isVirtual: false, pixels: pixels)]
      }

      mac.host.screenParametersChanged()
      await session.resizing?.value

      #expect(session.displayID == renumbered && session.displayFollow == nil)
      #expect(session.configuration.width == 3440 && session.configuration.height == 1440)
      #expect(mac.captureStarts.isEmpty && session.state == "viewing")
    }
  }
}
