#if os(macOS)
  import CoreMedia
  import CoreVideo
  import ScreenCaptureKit
  import Testing

  @testable import ScreenSharing
  @testable import ScreenSharingV2

  extension HardwareCodecTests {
    @Suite(.timeLimit(.minutes(1)))
    @MainActor struct ScreenSharingEncoderCaptureCadenceTests {
      private static let everyRefresh = CMTime(value: 1, timescale: 480)

      nonisolated static var shipsVideoProcessing: Bool {
        ScreenSharingVCPEngineTests.available && ScreenSharingV2EncoderKind.configured() == .videoProcessing
      }

      private static func capture(
        for encoder: any ScreenSharingTileEncoder, configuration: ScreenSharingVideoConfiguration, refreshHz: Double
      ) -> SCStreamConfigurationSummary {
        let stream = ScreenSharingCapture.streamConfiguration(
          configuration, pixelFormat: encoder.sourcePixelFormat, showsCursor: false, capturesAudio: false,
          cadence: .init(displayRefreshHz: refreshHz))
        return .init(interval: stream.minimumFrameInterval, pixelFormat: stream.pixelFormat)
      }

      struct SCStreamConfigurationSummary: Equatable {
        let interval: CMTime
        let pixelFormat: OSType
      }

      @Test(.enabled(if: shipsVideoProcessing, "The shipped encoder is not VideoProcessing on this machine."))
      func theShippedEncoderBehindItsRateSwitchIsFedEveryRefreshOfASixtyHertzDisplay() async throws {
        let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 3840, height: 2160)
        let encoder = try await ScreenSharingV2Encoders.make(
          .configured(), configuration: configuration, metrics: ScreenSharingMetrics())
        defer { encoder.stop() }

        #expect(encoder is ScreenSharingRateSwitchedTileEncoder)
        #expect(
          Self.capture(for: encoder, configuration: configuration, refreshHz: 60)
            == .init(interval: Self.everyRefresh, pixelFormat: kCVPixelFormatType_32BGRA))
        #expect(configuration.framesPerSecond == ScreenSharingV2Profile.framesPerSecond)
      }

      @Test func theFallbackEncoderIsFedEveryRefreshOfASixtyHertzDisplay() async throws {
        let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 3840, height: 2160)
        let encoder = try await ScreenSharingV2Encoders.make(
          .videoToolbox, configuration: configuration, metrics: ScreenSharingMetrics())
        defer { encoder.stop() }

        #expect(
          Self.capture(for: encoder, configuration: configuration, refreshHz: 60)
            == .init(interval: Self.everyRefresh, pixelFormat: ScreenSharingV2Profile.capturePixelFormat))
      }

      @Test(arguments: ScreenSharingV2EncoderKind.allCases)
      func neitherEncoderIsFedMoreThanSixtyFramesASecondFromAOneHundredTwentyHertzDisplay(
        kind: ScreenSharingV2EncoderKind
      ) async throws {
        let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 3024, height: 1964)
        let encoder = try await ScreenSharingV2Encoders.make(
          kind, configuration: configuration, metrics: ScreenSharingMetrics())
        defer { encoder.stop() }

        let interval = Self.capture(for: encoder, configuration: configuration, refreshHz: 120).interval

        #expect(interval.seconds > 1.0 / 120 * 1.8 && interval.seconds < 1.0 / 60)
      }
    }
  }
#endif
