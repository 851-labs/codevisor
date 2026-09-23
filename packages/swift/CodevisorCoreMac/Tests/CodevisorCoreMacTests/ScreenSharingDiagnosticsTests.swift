import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingDiagnosticsTests {
  @Test func relayTransportDescribesTheClientConnectionRatherThanItsUDPAllocation() {
    let diagnostics = ScreenSharingViewerDiagnostics()
    diagnostics.update(
      metrics: ScreenSharingMetrics().snapshot(),
      statistics: [
        "local-candidate.selected.candidateType": "relay",
        "local-candidate.selected.protocol": "udp",
        "local-candidate.selected.relayProtocol": "tls",
      ], now: 10)
    #expect(diagnostics.route == "Relay · TLS")
  }
  @Test func vncSessionsReportUpdateRateBandwidthSizeAndLatency() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    let statistics = ["vnc.transport": "WebSocket"]
    diagnostics.update(metrics: metrics.snapshot(), statistics: statistics, now: 10)
    #expect(diagnostics.route == "VNC · WebSocket")
    #expect(diagnostics.updatesPerSecond == nil)
    metrics.increment("vncUpdatesPublished", by: 20)
    metrics.increment("vncBytesReceived", by: 2_500_000)
    metrics.increment("presentedFrames", by: 20)
    for latency in [10.0, 20, 30, 40, 200] { metrics.observe("vncUpdateLatency", milliseconds: latency) }
    diagnostics.update(metrics: metrics.snapshot(), statistics: statistics, now: 12)
    #expect(diagnostics.updatesPerSecond == 10)
    #expect(diagnostics.framesPerSecond == 10)
    #expect(diagnostics.megabitsPerSecond == 10)
    #expect(diagnostics.bytesPerUpdate == 125_000)
    #expect(diagnostics.updateLatencyMilliseconds == metrics.snapshot().timings["vncUpdateLatency"]?.p95Ms)
    #expect(diagnostics.roundTripMilliseconds == nil, "No fence round trip measured yet.")
    metrics.label("vncUpdateMode", "continuous")
    metrics.observe("vncRoundTrip", milliseconds: 42)
    diagnostics.update(metrics: metrics.snapshot(), statistics: statistics, now: 13)
    #expect(diagnostics.roundTripMilliseconds == 42)
    #expect(diagnostics.route == "VNC · WebSocket · continuous")
  }

  @Test func webRTCSessionsHaveNoVNCUpdateFigures() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    diagnostics.update(metrics: metrics.snapshot(), statistics: [:], now: 10)
    metrics.increment("presentedFrames", by: 60)
    diagnostics.update(metrics: metrics.snapshot(), statistics: [:], now: 11)
    #expect(diagnostics.updatesPerSecond == nil)
    #expect(diagnostics.bytesPerUpdate == nil)
    #expect(diagnostics.updateLatencyMilliseconds == nil)
  }

  @Test func intervalRatesAndSelectedRouteUseOnlyMeasuredValues() {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    diagnostics.update(metrics: metrics.snapshot(), statistics: [:], now: 10)
    #expect(diagnostics.framesPerSecond == nil)
    #expect(diagnostics.roundTripMilliseconds == nil)
    #expect(diagnostics.route == "Connecting")
    metrics.increment("presentedFrames", by: 120)
    metrics.increment("renderDrops", by: 3)
    metrics.observe("decode", milliseconds: 2.5)
    metrics.label("videoSize", "1920 × 1080")
    metrics.label("decoder", "VideoToolbox hardware")
    diagnostics.update(
      metrics: metrics.snapshot(),
      statistics: [
        "inbound-rtp.video.bytesReceived": "3000000",
        "candidate-pair.selected.currentRoundTripTime": "0.012",
        "local-candidate.selected.candidateType": "relay",
        "remote-candidate.selected.candidateType": "host",
        "local-candidate.selected.protocol": "udp",
      ], now: 12)
    #expect(diagnostics.framesPerSecond == 60)
    #expect(diagnostics.megabitsPerSecond == 12)
    #expect(diagnostics.roundTripMilliseconds == 12)
    #expect(diagnostics.route == "Relay · UDP")
    #expect(diagnostics.resolution == "1920 × 1080")
    #expect(diagnostics.decodeMilliseconds == 2.5)
    #expect(diagnostics.droppedFrames == 3)
    // Reset or missing RTC counters cannot produce negative bitrate.
    diagnostics.update(metrics: metrics.snapshot(), statistics: [:], now: 13)
    #expect(diagnostics.framesPerSecond == 0)
    #expect(diagnostics.megabitsPerSecond == 0)
    #expect(diagnostics.roundTripMilliseconds == nil)
  }
}
