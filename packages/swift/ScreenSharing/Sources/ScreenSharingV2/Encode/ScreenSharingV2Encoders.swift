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

  public static func withVideoToolboxFallback(
    _ primary: any ScreenSharingTileEncoder, configuration: ScreenSharingVideoConfiguration,
    metrics: ScreenSharingMetrics
  ) -> ScreenSharingFallbackTileEncoder {
    ScreenSharingVideoToolboxWarmUp.start()
    return ScreenSharingFallbackTileEncoder(primary: primary, metrics: metrics) { layout in
      try ScreenSharingVideoToolboxTileEncoder(configuration: configuration, layout: layout, metrics: metrics)
    }
  }

  private static func videoProcessing(
    _ configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics
  ) async throws -> any ScreenSharingTileEncoder {
    try await ScreenSharingVCPSelfTest.pass()
    let layout = ScreenSharingV2Profile.tileLayout(for: configuration)
    let primary = try ScreenSharingVCPTileEncoder(configuration: configuration, layout: layout, metrics: metrics)
    let fast = withVideoToolboxFallback(primary, configuration: configuration, metrics: metrics)
    return withVideoToolboxOnSlowLinks(fast, configuration: configuration, metrics: metrics)
  }

  private static func withVideoToolboxOnSlowLinks(
    _ fast: any ScreenSharingTileEncoder, configuration: ScreenSharingVideoConfiguration,
    metrics: ScreenSharingMetrics
  ) -> any ScreenSharingTileEncoder {
    do {
      let slow = try ScreenSharingVideoToolboxTileEncoder(
        configuration: configuration, layout: fast.layout, metrics: metrics)
      let switched = try ScreenSharingRateSwitchedTileEncoder(
        fast: fast, slow: slow, bitrate: configuration.bitrate, metrics: metrics)
      metrics.label("encoder", Self.switchedLabel)
      return switched
    } catch {
      metrics.label("encoderRouteError", error.localizedDescription)
      return fast
    }
  }

  private static var switchedLabel: String {
    let fastFrom = Double(ScreenSharingV2EncoderRoute.fastFromBitrate) / 1_000_000
    let slowBelow = Double(ScreenSharingV2EncoderRoute.slowBelowBitrate) / 1_000_000
    return "VideoProcessing VCP HEVC 4:4:4 from \(fastFrom) Mbit/s, VideoToolbox HEVC Main below \(slowBelow) Mbit/s"
  }
}
