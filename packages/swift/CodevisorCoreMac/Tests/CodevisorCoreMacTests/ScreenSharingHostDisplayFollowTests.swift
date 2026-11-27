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

  @Test func aDisplayThatChangedSizeAndIsLaterRenumberedIsStillTheSharedDisplay() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let resized = ServerScreenSharingDisplay(id: Self.wide.id, name: Self.wide.name, width: 1720, height: 720)
      mac.displays = [Fixture.main, resized]
      mac.host.screenParametersChanged()

      let renumbered = CGMainDisplayID() &+ 9
      let builtIn = ScreenSharingDisplayIdentity.Online(
        id: Fixture.displayID(of: Fixture.main), identity: .init(vendor: 1, model: 1, serial: 1), isMain: true,
        isVirtual: false, pixels: .init(width: 1280, height: 720))
      let shared = ScreenSharingDisplayIdentity.Online(
        id: renumbered, identity: session.displayIdentity, isMain: false, isVirtual: false,
        pixels: .init(width: 1720, height: 720))
      mac.host.onlineDisplays = { [builtIn, shared] }
      mac.host.screenParametersChanged()
      await session.resizing?.value

      #expect(session.displayID == renumbered && session.displayFollow == nil, "not left for the main display")
      #expect(mac.captureStarts.isEmpty && session.state == "viewing")
    }
  }

  @Test func aHeadlessMacsFramebufferBackUnderANewNumberAndSizeIsStillTheSharedDisplay() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.standIn]
      _ = await mac.send(mac.start(as: .macBook, .open))
      let session = try #require(mac.host.current)
      session.state = "viewing"
      let back = ServerScreenSharingDisplay(id: Fixture.standInAgain.id, name: "Display", width: 1280, height: 720)

      mac.displays = [back]
      mac.host.screenParametersChanged()
      await session.resizing?.value

      #expect(session.displayID == Fixture.displayID(of: back) && session.displayFollow == nil)
      #expect(session.configuration.width == 1920 && session.configuration.height == 1080)
      #expect(mac.captureStarts.isEmpty && session.state == "viewing")
    }
  }

  @Test func whenTheDisplayIsBackBeforeTheMoveRunsTheStoppedCaptureGetsTheUsualRestart() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      mac.host.displayListCatchUp = .zero
      mac.displays = [Fixture.main]
      session.capture.onStopped?(Self.gone)
      #expect(session.displayFollow != nil && session.state == "viewing")

      mac.displays = [Fixture.main, Self.wide]
      await session.resizing?.value
      await session.captureTask?.value

      #expect(session.state == "connecting" && session.metrics.counter("captureRestarts") == 1)
      #expect(session.displayID == Fixture.displayID(of: Self.wide) && session.displayFollow == nil)
    }
  }

  @Test func aCaptureThatStopsAgainWhileTheMoveIsFinishingGetsTheUsualRestart() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      var stoppedAgain = false
      mac.listDisplays = { [unowned mac] in
        if mac.captureStarts == ["main"], !stoppedAgain {
          stoppedAgain = true
          session.capture.onStopped?(Self.gone)
        }
        return mac.displays
      }

      mac.displays = [Fixture.main]
      mac.host.screenParametersChanged()
      await session.resizing?.value

      #expect(stoppedAgain && session.displayID == Fixture.displayID(of: Fixture.main))
      #expect(session.state == "connecting" && session.metrics.counter("captureRestarts") == 1)
    }
  }

  @Test func aCaptureStopThatBeatsTheDisplayListStillMovesTheSessionAndKeepsItViewing() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      mac.host.displayListCatchUp = .zero

      session.capture.onStopped?(Self.gone)
      #expect(session.state == "viewing" && session.displayFollow == nil, "it waits for the display list first")
      mac.displays = [Fixture.main]
      await session.captureTask?.value
      await session.resizing?.value

      await expectMovedToMain(session, on: mac)
    }
  }

  @Test func aCaptureThatStopsWhileEveryDisplayStaysGetsTheUsualRestart() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      mac.host.displayListCatchUp = .zero

      session.capture.onStopped?("Failed during stream due to application connection being interrupted")
      await session.captureTask?.value

      #expect(session.state == "connecting" && session.metrics.counter("captureRestarts") == 1)
      #expect(session.displayFollow == nil && session.displayID == Fixture.displayID(of: Self.wide))
    }
  }

  @Test func aRefreshRateFollowLeavesTheResizeInFlightToTheSession() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let (released, release) = AsyncStream<Void>.makeStream()
      let resize = Task<Void, Never> { for await _ in released { break } }
      session.resizing = resize

      mac.host.followDisplayRefresh(session)

      #expect(session.resizing == resize && session.refreshFollow != nil)
      release.finish()
      await session.refreshFollow?.value
    }
  }

  @Test func endingTheSessionCancelsARefreshRateFollow() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let (released, release) = AsyncStream<Void>.makeStream()
      session.refreshFollow = Task<Void, Never> { for await _ in released { break } }
      mac.host.followDisplayRefresh(session)
      let follow = try #require(session.refreshFollow)

      await mac.host.end(session)

      #expect(follow.isCancelled)
      release.finish()
    }
  }

  @Test func aNewerRefreshRateFollowCancelsTheOneBefore() async throws {
    try await Fixture.run { mac in
      let session = try await viewing(mac)
      let (released, release) = AsyncStream<Void>.makeStream()
      session.refreshFollow = Task<Void, Never> { for await _ in released { break } }
      let first = try #require(session.refreshFollow)

      mac.host.followDisplayRefresh(session)

      #expect(first.isCancelled && session.refreshFollow != first)
      release.finish()
      await session.refreshFollow?.value
    }
  }
}
