import ScreenSharing
import ScreenSharingV2

struct V2EncoderChoice {
  static let usage = "[--encoder vt|vcp] [--vcp-fail-after <seconds>]"
  private static let failureDelays = 1...3600

  let kind: ScreenSharingV2EncoderKind
  let failAfter: Duration?

  @MainActor
  init(options: BenchOptions) throws {
    kind = try options.choice("encoder", default: ScreenSharingV2EncoderKind.configured())
    let seconds = try options.integer("vcp-fail-after", default: 0, in: 0...Self.failureDelays.upperBound)
    failAfter = seconds > 0 ? .seconds(seconds) : nil
    guard failAfter == nil || kind == .videoProcessing else {
      throw BenchUsageError(message: "--vcp-fail-after needs --encoder vcp")
    }
  }

  func make(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws
    -> any ScreenSharingTileEncoder
  {
    guard let failAfter else { return try await Self.make(kind, configuration: configuration, metrics: metrics) }

    return try forcedToFail(after: failAfter, configuration: configuration, metrics: metrics)
  }

  static func make(
    _ kind: ScreenSharingV2EncoderKind, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws -> any ScreenSharingTileEncoder {
    let encoder = try await ScreenSharingV2Encoders.make(kind, configuration: configuration, metrics: metrics)
    guard kind == .videoProcessing, metrics.counter("encoderFallbacks") > 0 else { return encoder }

    encoder.stop()
    let reason = metrics.label("encoderFallbackReason") ?? "unknown"
    throw BenchUsageError(message: "--encoder vcp is unavailable on this Mac: \(reason)")
  }

  private func forcedToFail(
    after delay: Duration, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) throws -> any ScreenSharingTileEncoder {
    let fallback = try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: metrics)
    let primary = try ScreenSharingVCPTileEncoder(
      configuration: configuration, layout: fallback.layout, metrics: metrics)
    let failing = V2ForcedFailureEncoder(primary, after: delay, metrics: metrics)
    return try ScreenSharingFallbackTileEncoder(primary: failing, fallback: fallback, metrics: metrics)
  }
}
