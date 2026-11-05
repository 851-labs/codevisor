import ScreenSharing

public enum ScreenSharingV2Encoders {
  public static func make(
    _ kind: ScreenSharingV2EncoderKind, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws -> any ScreenSharingTileEncoder {
    guard kind == .videoProcessing else {
      return try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: metrics)
    }

    do {
      return try await videoProcessing(configuration, metrics: metrics)
    } catch {
      metrics.increment("encoderFallbacks")
      metrics.label("encoderFallbackReason", error.localizedDescription)
      return try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, metrics: metrics)
    }
  }

  public static func warmUpVideoToolbox() {
    ScreenSharingVideoToolboxWarmUp.start()
  }

  private static func videoProcessing(
    _ configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws -> any ScreenSharingTileEncoder {
    try await ScreenSharingVCPSelfTest.pass()
    let primary = try ScreenSharingVCPTileEncoder(
      configuration: configuration, layout: ScreenSharingV2Profile.tileLayout(for: configuration), metrics: metrics)
    warmUpVideoToolbox()
    return ScreenSharingFallbackTileEncoder(primary: primary, metrics: metrics) { layout in
      try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, layout: layout, metrics: metrics)
    }
  }
}
