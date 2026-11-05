import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingViewerDiagnosticsTests {
  @Test func engineV2ReportsItsRouteRoundTripBitrateAndRecovery() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    var statistics = [
      "v2.engine": "v2", "v2.route": "direct", "v2.roundTripMs": "1.5", "v2.bytesReceived": "1000000",
      "v2.lossPercent": "0.25", "v2.nacksSent": "3", "v2.recoveredByFEC": "1", "v2.framesSkipped": "0",
    ]
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: statistics, now: 10)
    #expect(diagnostics.engine == "v2 · QUIC")
    #expect(diagnostics.route == "Direct")
    #expect(diagnostics.roundTripMilliseconds == 1.5)
    #expect(diagnostics.recovery == "0.2% loss · 3 NACK · 1 FEC · 0 skipped")
    statistics["v2.bytesReceived"] = "3500000"
    statistics["v2.route"] = "relay"
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: statistics, now: 12)
    #expect(diagnostics.megabitsPerSecond == 10)
    #expect(diagnostics.route == "Relay")
  }

  @Test func vncSessionsReportUpdateRateBandwidthSizeAndLatency() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    let statistics = ["vnc.transport": "WebSocket"]
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: statistics, now: 10)
    #expect(diagnostics.route == "VNC · WebSocket")
    #expect(diagnostics.updatesPerSecond == nil)
    metrics.increment("vncUpdatesPublished", by: 20)
    metrics.increment("vncBytesReceived", by: 2_500_000)
    metrics.increment("presentedFrames", by: 20)
    for latency in [10.0, 20, 30, 40, 200] { metrics.observe("vncUpdateLatency", milliseconds: latency) }
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: statistics, now: 12)
    #expect(diagnostics.updatesPerSecond == 10)
    #expect(diagnostics.framesPerSecond == 10)
    #expect(diagnostics.megabitsPerSecond == 10)
    #expect(diagnostics.bytesPerUpdate == 125_000)
    #expect(diagnostics.updateLatencyMilliseconds == metrics.snapshot().timings["vncUpdateLatency"]?.p95Ms)
    #expect(diagnostics.roundTripMilliseconds == nil, "No fence round trip measured yet.")
    metrics.label("vncUpdateMode", "continuous")
    metrics.observe("vncRoundTrip", milliseconds: 42)
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: statistics, now: 13)
    #expect(diagnostics.roundTripMilliseconds == 42)
    #expect(diagnostics.route == "VNC · WebSocket · continuous")
  }

  @Test func v2SessionsHaveNoVNCUpdateFigures() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    diagnostics.update(
      metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: ["v2.engine": "v2"], now: 10)
    metrics.increment("presentedFrames", by: 60)
    diagnostics.update(
      metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: ["v2.engine": "v2"], now: 11)
    #expect(diagnostics.updatesPerSecond == nil)
    #expect(diagnostics.bytesPerUpdate == nil)
    #expect(diagnostics.updateLatencyMilliseconds == nil)
  }

  @Test func intervalRatesAndSelectedRouteUseOnlyMeasuredValues() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 10)
    #expect(diagnostics.framesPerSecond == nil)
    #expect(diagnostics.roundTripMilliseconds == nil)
    #expect(diagnostics.route == "Connecting")
    metrics.increment("presentedFrames", by: 120)
    metrics.increment("renderDrops", by: 3)
    metrics.observe("decode", milliseconds: 2.5)
    metrics.label("videoSize", "1920 × 1080")
    metrics.label("decoder", "VideoToolbox hardware")
    diagnostics.update(
      metrics: metrics.snapshot(), timeline: metrics.timeline,
      statistics: ["v2.engine": "v2", "v2.bytesReceived": "3000000", "v2.roundTripMs": "12", "v2.route": "relay"],
      now: 12)
    #expect(diagnostics.framesPerSecond == 60)
    #expect(diagnostics.megabitsPerSecond == 12)
    #expect(diagnostics.roundTripMilliseconds == 12)
    #expect(diagnostics.route == "Relay")
    #expect(diagnostics.resolution == "1920 × 1080")
    #expect(diagnostics.decodeMilliseconds == 2.5)
    #expect(diagnostics.droppedFrames == 3)
    diagnostics.update(
      metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: ["v2.engine": "v2"], now: 13)
    #expect(diagnostics.framesPerSecond == 0)
    #expect(diagnostics.megabitsPerSecond == 0)
    #expect(diagnostics.roundTripMilliseconds == nil)
  }
}

@MainActor
struct ScreenSharingStreamsDiagnosticsTests {
  @Test func theStreamsLineListsWhatTheSessionReported() {
    #expect(ScreenSharingViewerDiagnostics.streams([:]) == nil)
    #expect(
      ScreenSharingViewerDiagnostics.streams([
        "pointer": "streamed", "audioTargetDelayMs": "105", "desktopResize": "1280×800 pt",
      ]) == "pointer streamed · sound 105 ms behind · display 1280×800 pt")
  }
}
