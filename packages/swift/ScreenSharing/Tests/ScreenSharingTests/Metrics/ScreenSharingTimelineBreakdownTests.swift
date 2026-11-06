import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingTimelineBreakdownTests {
  private static let ms: Int64 = 1_000_000

  @Test func connectionDetailsShowEachV2StageAndTheMeasuredCaptureToScreen() throws {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    metrics.timeline.observeTransport(networkUs: 1_000, jitterBufferUs: 0)
    for index in 1...20 { present(metrics.timeline, source: Int64(index) * 100 * Self.ms, decodeMs: Int64(index)) }
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 10)

    let timeline = try #require(diagnostics.timeline)
    #expect(
      timeline.stages.map(\.label) == [
        "Capture", "Host queue", "Encode", "Hand-off", "Network", "Assemble", "Decode", "Deliver", "Render queue",
        "Commit → screen",
      ])
    let decode = try #require(timeline.stages.first { $0.label == "Decode" })
    #expect(decode.value == "11.0 / 20.0 ms" && decode.p50 == "11.0 ms" && decode.p95 == "20.0 ms")
    #expect(timeline.stages.first { $0.label == "Hand-off" }?.value == "0.5 / 0.5 ms")
    #expect(timeline.total?.label == "Capture → screen" && timeline.total?.value == "22.5 / 31.5 ms")
    #expect(timeline.caption == "The last 20 frames. Network is half the round trip.")
  }

  @Test func theSummaryCoversOnlyTheMostRecentFramesAndKeepsItsLastValueWhileIdle() throws {
    let metrics = ScreenSharingMetrics()
    let diagnostics = ScreenSharingViewerDiagnostics()
    metrics.timeline.observeTransport(networkUs: 1_000, jitterBufferUs: 0)
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 10)
    #expect(diagnostics.timeline == nil, "no frame has reached the screen yet")

    let window = ScreenSharingViewerDiagnostics.timelineWindow
    for index in 1...window { present(metrics.timeline, source: Int64(index) * 100 * Self.ms, decodeMs: 30) }
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 11)
    for index in 1...window {
      present(metrics.timeline, source: Int64(window + index) * 100 * Self.ms, decodeMs: 2)
    }
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 12)
    diagnostics.update(metrics: metrics.snapshot(), timeline: metrics.timeline, statistics: [:], now: 13)

    let timeline = try #require(diagnostics.timeline)
    #expect(timeline.frames == window)
    #expect(timeline.stages.first { $0.label == "Decode" }?.value == "2.0 / 2.0 ms")
    #expect(timeline.stages.first { $0.label == "Decode" }?.timing.count == window)
  }

  private func present(_ timeline: ScreenSharingFrameTimeline, source: Int64, decodeMs: Int64) {
    let host = ScreenSharingHostFrameTiming(
      clock: ScreenSharingClockIdentity.current, captureUs: 1_000, hostQueueUs: 1_000, encodeUs: 2_000,
      handOffUs: 500)
    let decodeInput = source + 6_500_000
    let decoded = decodeInput + decodeMs * Self.ms
    timeline.decoded(
      ScreenSharingDecodedFrameTiming(
        sourceTimestampNs: source, host: host, assembleUs: 1_000, decodeInputNs: decodeInput,
        decodeSubmitNs: decodeInput, decodedNs: decoded, isKeyFrame: false))
    timeline.presented(
      sourceTimestampNs: source,
      ScreenSharingFramePresentation(
        receivedAtNs: decoded, submittedAtNs: decoded + Self.ms, presentedAtNs: decoded + 5 * Self.ms))
  }
}
