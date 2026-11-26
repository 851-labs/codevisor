import CodevisorTestSupport
import CoreVideo
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

extension HardwareCodecTests {
  @Suite(.timeLimit(.minutes(1)))
  struct ScreenSharingVCPSmallChangeTests {
    private struct Stream {
      let host: ScreenSharingV2Host
      let viewer: ScreenSharingV2Viewer
      let decoded: DecodedFrames
      let clock: ManualScheduler
      let encoderMetrics: ScreenSharingMetrics

      func stop() {
        host.stop()
        viewer.stop()
      }
    }

    private static let background: UInt8 = 128
    private static let fastLinkBitsPerSecond = 100_000_000
    private static let refinementGapPastTheNextRefreshNs =
      ScreenSharingV2Profile.refinementGapNs + ScreenSharingV2RefreshPhase().periodNs

    static var shipsVideoProcessing: Bool {
      ScreenSharingVCPEngineTests.available && ScreenSharingV2EncoderKind.configured() == .videoProcessing
    }

    @Test(.enabled(if: shipsVideoProcessing, "The shipped encoder is not VideoProcessing on this machine."))
    func aSmallChangeToATileThatWasJustSharpenedIsEncodedWithoutSwitchingTheCapAgain() async throws {
      let stream = try await Self.sharpenedAfterASmallChange()
      defer { stream.stop() }

      stream.host.push(try Self.patch(seed: 2).painted(on: Self.background, timestampNs: 3_000))
      await stream.decoded.arrivals.cancellableWait(for: 4)

      #expect(stream.encoderMetrics.label("encoderRoute") == "fast")
      #expect(stream.decoded.sourceTimestamps.last == 3_000)
      #expect(stream.encoderMetrics.counter("encoderQPCapChanges") == 1)
    }

    @Test(.enabled(if: shipsVideoProcessing, "The shipped encoder is not VideoProcessing on this machine."))
    func aLargeChangeToATileThatWasJustSharpenedGoesBackToTheNormalCap() async throws {
      let stream = try await Self.sharpenedAfterASmallChange()
      defer { stream.stop() }

      stream.host.push(try TestBGRAPixels.noise(timestampNs: 3_000))
      await stream.decoded.arrivals.cancellableWait(for: 4)

      #expect(stream.encoderMetrics.label("encoderRoute") == "fast")
      #expect(stream.decoded.sourceTimestamps.last == 3_000)
      #expect(stream.encoderMetrics.counter("encoderQPCapChanges") == 2)
    }

    private static func patch(seed: Int) -> TestNoisePatch {
      TestNoisePatch(rows: 64..<96, columns: 64..<96, seed: seed)
    }

    private static func sharpenedAfterASmallChange() async throws -> Stream {
      let stream = try await onTheFastRoute()
      stream.host.push(try TestBGRAPixels.frame(shades: [background], timestampNs: 1_000))
      await stream.decoded.arrivals.cancellableWait(for: 1)
      stream.host.push(try patch(seed: 1).painted(on: background, timestampNs: 2_000))
      await stream.decoded.arrivals.cancellableWait(for: 2)
      stream.clock.advance(byNs: refinementGapPastTheNextRefreshNs)
      await stream.decoded.arrivals.cancellableWait(for: 3)
      return stream
    }

    private static func onTheFastRoute() async throws -> Stream {
      let (hostSide, viewerSide) = LoopbackMediaTransport.pair()
      try await HardwareEncoderBudget.require(vcpTiles: 1, videoToolboxTiles: 2)
      let routeClock = ManualScheduler()
      let encoderMetrics = ScreenSharingMetrics()
      let encoder = try await ScreenSharingV2Encoders.make(
        ScreenSharingV2EncoderKind.configured(),
        configuration: try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360),
        metrics: encoderMetrics, scheduler: routeClock)
      routeClock.step(byNs: ScreenSharingV2EncoderRoute.fastAfterNs)
      encoder.observeNetwork(
        ScreenSharingTileNetworkFeedback(
          packetErrorRate: 0, roundTripDelayMs: 20, transmissionBitsPerSecond: fastLinkBitsPerSecond,
          transmissionMeasured: true))
      let clock = ManualScheduler()
      let host = ScreenSharingV2Host(
        transport: hostSide, encoder: encoder, metrics: ScreenSharingMetrics(),
        initialBitrate: ScreenSharingV2Profile.bitrateCeiling, scheduler: clock)
      let viewer = ScreenSharingV2Viewer(transport: viewerSide, metrics: ScreenSharingMetrics())
      let decoded = DecodedFrames(viewer.frames)
      host.start()
      viewer.start()
      return Stream(host: host, viewer: viewer, decoded: decoded, clock: clock, encoderMetrics: encoderMetrics)
    }
  }
}
