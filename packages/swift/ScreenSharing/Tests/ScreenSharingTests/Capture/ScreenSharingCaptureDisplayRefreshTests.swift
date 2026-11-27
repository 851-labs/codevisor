#if os(macOS)
  import CoreMedia
  import Testing

  @testable import ScreenSharing

  @Suite(.timeLimit(.minutes(1))) @MainActor struct ScreenSharingCaptureDisplayRefreshTests {
    private final class Refresh {
      var hz: Double?
      init(_ hz: Double?) { self.hz = hz }
    }

    private static let everyRefresh = CMTime(value: 1, timescale: 480)
    private static let everyOtherRefreshAt120 = CMTime(value: 15_625_000, timescale: 1_000_000_000)

    private func start(_ fixture: CaptureFixture, refresh: Refresh) async throws {
      try await fixture.capture.start(
        target: fixture.target, configuration: .init(), sink: fixture.sink, metrics: fixture.metrics,
        displayRefresh: { refresh.hz })
    }

    @Test func aSixtyHertzDisplayIsCapturedAtEveryRefreshAndTheEncoderRateStaysSixty() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))

      let settings = try #require(fixture.target.settings)
      #expect(settings.interval == Self.everyRefresh)
      #expect(fixture.metrics.label("captureDisplayRefreshHz") == "60.0")
      #expect(fixture.metrics.label("captureMinimumFrameIntervalNs") == "2083333")
    }

    @Test func aOneHundredTwentyHertzDisplayIsCapturedAtEveryOtherRefresh() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(120))

      #expect(fixture.target.settings?.interval == Self.everyOtherRefreshAt120)
    }

    @Test func aResizeKeepsTheDisplaysCadence() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))

      try await fixture.capture.update(configuration: .init(width: 1280, height: 720))

      #expect(fixture.stream.updated?.interval == Self.everyRefresh && fixture.stream.updated?.width == 1280)
    }

    @Test func aDisplaySwitchedToSixtyHertzMidSessionIsCapturedAtEveryRefreshFromThen() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)

      refresh.hz = 60
      try await fixture.capture.followDisplayRefresh()

      #expect(fixture.stream.calls == [.start, .update])
      #expect(fixture.stream.updated?.interval == Self.everyRefresh)
      #expect(fixture.capture.cadence.displayRefreshHz == 60)
      #expect(fixture.metrics.label("captureDisplayRefreshHz") == "60.0")
    }

    @Test func anUnchangedRefreshRateLeavesTheStreamAlone() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))

      try await fixture.capture.followDisplayRefresh()

      #expect(fixture.stream.calls == [.start])
    }

    @Test func aFailedReconfigurationKeepsThePreviousCadence() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)
      fixture.stream.updateFailure = CancellationError()

      refresh.hz = 60
      await #expect(throws: CancellationError.self) { try await fixture.capture.followDisplayRefresh() }

      #expect(fixture.capture.cadence.displayRefreshHz == 120)
    }

    @Test func aStoppedCaptureDoesNotReconfigure() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)
      try await fixture.capture.stop()

      refresh.hz = 60
      try await fixture.capture.followDisplayRefresh()

      #expect(fixture.stream.calls == [.start, .stop])
    }

    @Test func aRestartForAudioKeepsTheDisplaysCadence() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))

      try await fixture.capture.setCapturesAudio(true)

      #expect(fixture.stream.calls == [.start, .stop, .start])
      #expect(fixture.target.settings?.interval == Self.everyRefresh)
    }

    @Test(arguments: [ScreenSharingDynamicRange.standard, .high])
    func everyCaptureFormatAsksForTheDisplaysCadence(range: ScreenSharingDynamicRange) throws {
      for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
        let config = ScreenSharingCapture.streamConfiguration(
          try .init(), pixelFormat: format, showsCursor: false, capturesAudio: false, dynamicRange: range,
          cadence: .init(displayRefreshHz: 60))
        #expect(config.minimumFrameInterval == Self.everyRefresh)
      }
    }

    @Test func aStartWithoutARefreshSourceDoesNotKeepTheLastDisplays() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))
      try await fixture.capture.stop()

      try await fixture.start()

      #expect(fixture.capture.cadence.displayRefreshHz == ScreenSharingCaptureCadence.unknownDisplayRefreshHz)
    }

    @Test func aFollowThatFailsAfterARestartKeepsTheNewCaptureCadence() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)
      let held = CaptureGate()
      fixture.stream.holdUpdate = held
      fixture.stream.updateFailure = CancellationError()
      refresh.hz = 60
      let follow = Task { @MainActor in try await fixture.capture.followDisplayRefresh() }
      await held.entered.wait()

      try await fixture.capture.stop()
      fixture.stream.holdStart = nil
      try await start(fixture, refresh: Refresh(144))
      held.release()
      _ = try? await follow.value

      #expect(fixture.capture.cadence.displayRefreshHz == 144)
    }

    @Test func aRefreshRateThatCannotBeReadMidSessionKeepsTheCadence() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(60)
      try await start(fixture, refresh: refresh)

      refresh.hz = nil
      try await fixture.capture.followDisplayRefresh()

      #expect(fixture.stream.calls == [.start])
      #expect(fixture.capture.cadence.displayRefreshHz == 60)
    }

    @Test func aRefreshRateThatAsksForTheSameIntervalOnlyRelabels() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(60)
      try await start(fixture, refresh: refresh)

      refresh.hz = 59.94
      try await fixture.capture.followDisplayRefresh()

      #expect(fixture.stream.calls == [.start])
      #expect(fixture.metrics.label("captureDisplayRefreshHz") == "59.94")
    }

    @Test func aFollowDuringAResizeWaitsAndKeepsTheNewSize() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)
      let held = CaptureGate()
      fixture.stream.holdUpdate = held
      let resize = Task { @MainActor in try await fixture.capture.update(configuration: .init(width: 1280, height: 720))
      }
      await held.entered.wait()

      refresh.hz = 60
      let follow = Task { @MainActor in try await fixture.capture.followDisplayRefresh() }
      for _ in 0..<20 { await Task.yield() }
      #expect(fixture.capture.queuedReconfigurations == 2, "the follow waits behind the resize")
      held.release()
      try await resize.value
      try await follow.value

      #expect(fixture.stream.calls == [.start, .update, .update])
      #expect(fixture.stream.updated?.width == 1280 && fixture.stream.updated?.interval == Self.everyRefresh)
    }

    @Test func aReconfigurationStuckOnAStoppedStreamDoesNotHoldUpTheRestartedOne() async throws {
      let fixture = CaptureFixture()
      try await start(fixture, refresh: Refresh(60))
      let stuck = CaptureGate()
      fixture.stream.holdUpdate = stuck
      let lost = Task { @MainActor in try? await fixture.capture.update(configuration: .init(width: 1280, height: 720))
      }
      await stuck.entered.wait()
      try await fixture.capture.stop()
      fixture.stream.holdUpdate = nil
      try await start(fixture, refresh: Refresh(60))

      try await fixture.capture.setShowsCursor(false)

      #expect(fixture.stream.updated?.showsCursor == false)
      stuck.release()
      await lost.value
    }

    @Test func aReconfigurationWaitsForARestartInProgress() async throws {
      let fixture = CaptureFixture()
      let refresh = Refresh(120)
      try await start(fixture, refresh: refresh)
      try await fixture.capture.stop()
      let starting = CaptureGate()
      fixture.stream.holdStart = starting
      let restart = Task { @MainActor in try await start(fixture, refresh: refresh) }
      await starting.entered.wait()

      refresh.hz = 60
      let follow = Task { @MainActor in try await fixture.capture.followDisplayRefresh() }
      for _ in 0..<20 { await Task.yield() }
      #expect(fixture.stream.calls == [.start, .stop], "no update while the stream is starting")
      starting.release()
      try await restart.value
      try await follow.value

      #expect(fixture.stream.calls == [.start, .stop, .start, .update])
      #expect(fixture.stream.updated?.interval == Self.everyRefresh)
    }

    @Test func aSettingWaitingBehindAResizeIsNotAppliedByTheResize() async throws {
      let fixture = CaptureFixture(capture: ScreenSharingCapture(pixelFormat: kCVPixelFormatType_32BGRA))
      try await start(fixture, refresh: Refresh(60))
      let held = CaptureGate()
      fixture.stream.holdUpdate = held
      let first = Task { @MainActor in try await fixture.capture.update(configuration: .init(width: 1600, height: 900))
      }
      await held.entered.wait()
      let resize = Task { @MainActor in try await fixture.capture.update(configuration: .init(width: 1280, height: 720))
      }
      let hdr = Task { @MainActor in try await fixture.capture.setDynamicRange(.high) }
      for _ in 0..<20 { await Task.yield() }

      held.release()
      try await first.value
      try await resize.value
      try await hdr.value

      let formats = fixture.stream.updates.map(\.pixelFormat)
      #expect(
        formats == [
          kCVPixelFormatType_32BGRA, kCVPixelFormatType_32BGRA, ScreenSharingDynamicRange.highCapturePixelFormat,
        ])
    }
  }
#endif
