import ScreenSharing

public enum ScreenSharingV2Encoders {
  public static func make(
    _ kind: ScreenSharingV2EncoderKind, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws -> any ScreenSharingTileEncoder {
    let videoToolbox = try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: metrics)
    guard kind == .videoProcessing else { return videoToolbox }

    do {
      return try await videoProcessing(configuration, metrics: metrics, fallback: videoToolbox)
    } catch {
      metrics.increment("encoderFallbacks")
      metrics.label("encoderFallbackReason", error.localizedDescription)
      return videoToolbox
    }
  }

  private static func videoProcessing(
    _ configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    fallback: any ScreenSharingTileEncoder
  ) async throws -> any ScreenSharingTileEncoder {
    try await ScreenSharingVCPSelfTest.pass()
    let primary = try ScreenSharingVCPTileEncoder(
      configuration: configuration, layout: fallback.layout, metrics: metrics)
    return try ScreenSharingFallbackTileEncoder(primary: primary, fallback: fallback, metrics: metrics)
  }
}
