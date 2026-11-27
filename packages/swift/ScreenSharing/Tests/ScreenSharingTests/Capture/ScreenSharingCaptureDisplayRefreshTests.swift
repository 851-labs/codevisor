#if os(macOS)
  import CoreMedia
  import Testing

  @testable import ScreenSharing

  @Suite @MainActor struct ScreenSharingCaptureDisplayRefreshTests {
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
      #expect(fixture.capture.cadence == ScreenSharingCaptureCadence(displayRefreshHz: 60))
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

      #expect(fixture.capture.cadence == ScreenSharingCaptureCadence(displayRefreshHz: 120))
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
  }
#endif
