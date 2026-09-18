import ScreenSharing
import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigTelemetryTests {
  static func statistics(bytesReceived: Int, rtt: Double = 0.004) -> [String: String] {
    [
      "inbound-rtp.RTCIn1.bytesReceived": String(bytesReceived),
      "inbound-rtp.RTCIn1.jitterBufferDelay": "1.0", "inbound-rtp.RTCIn1.jitterBufferEmittedCount": "10",
      "inbound-rtp.RTCIn1.keyFramesDecoded": "2", "inbound-rtp.RTCIn1.nackCount": "3",
      "candidate-pair.P1.currentRoundTripTime": String(rtt), "candidate-pair.P1.availableOutgoingBitrate": "25000000",
      "local-candidate.L1.candidateType": "host", "local-candidate.L1.protocol": "udp",
      "remote-candidate.R1.candidateType": "host",
    ]
  }

  @Test func ratesUseDeltasOverTheInterval() {
    var reducer = RigTelemetryReducer()
    let first = ScreenSharingMetrics()
    first.increment("presentedFrames", by: 100)
    let initial = reducer.reduce(
      elapsed: 10, role: "viewer", connection: "connected", sessionID: "s", snapshot: first.snapshot(),
      statistics: Self.statistics(bytesReceived: 1_000_000), mailboxDrops: 0, frameSize: "1920×1080")
    #expect(initial.presentedFramesPerSecond == nil, "no rate without a previous sample")
    #expect(initial.receiveMegabitsPerSecond == nil)
    #expect(initial.roundTripMilliseconds == 4)
    #expect(initial.candidatePair == "host/udp→host")
    #expect(initial.availableOutgoingKilobits == 25000)
    #expect(initial.keyFramesDecoded == 2)
    #expect(initial.nackCount == 3)
    #expect(initial.frameSize == "1920×1080")
    first.increment("presentedFrames", by: 120)
    let next = reducer.reduce(
      elapsed: 12, role: "viewer", connection: "connected", sessionID: "s", snapshot: first.snapshot(),
      statistics: Self.statistics(bytesReceived: 4_000_000), mailboxDrops: 1, frameSize: nil)
    #expect(next.presentedFramesPerSecond == 60)
    #expect(next.receiveMegabitsPerSecond == 12)
    #expect(next.mailboxDrops == 1)
    // jitterBufferDelay did not advance between samples: no interval mean.
    #expect(next.jitterBufferMeanMilliseconds == nil)
  }

  @Test func resetForgetsThePreviousSession() {
    var reducer = RigTelemetryReducer()
    let metrics = ScreenSharingMetrics()
    metrics.increment("presentedFrames", by: 50)
    _ = reducer.reduce(
      elapsed: 1, role: "viewer", connection: "connected", sessionID: "a", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    reducer.reset()
    let fresh = ScreenSharingMetrics()
    let sample = reducer.reduce(
      elapsed: 2, role: "viewer", connection: "connected", sessionID: "b", snapshot: fresh.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(sample.presentedFramesPerSecond == nil)
  }

  @Test func statisticLookupPrefersTheFirstSortedKey() {
    let values = ["candidate-pair.B.currentRoundTripTime": "2", "candidate-pair.A.currentRoundTripTime": "1"]
    #expect(RigTelemetryReducer.statistic(values, type: "candidate-pair", field: "currentRoundTripTime") == "1")
    #expect(RigTelemetryReducer.statistic(values, type: "inbound-rtp", field: "currentRoundTripTime") == nil)
  }

  @Test func hudLinesDescribeEachRole() {
    let build = RigBuildInfo(commit: "abcdef12", dirty: false, configuration: "release", builtAt: "")
    let waiting = RigHUDFormatter.lines(
      sample: nil, role: .viewer, name: "mac", build: build, peerName: nil, peerBuild: nil, reconnects: 2,
      capture: nil)
    #expect(waiting == ["viewer mac · abcdef12 release", "connection: waiting · reconnects 2"])
    var reducer = RigTelemetryReducer()
    let metrics = ScreenSharingMetrics()
    metrics.label("captureSize", "1920 × 1080")
    metrics.label("captureFPS", "60")
    let sample = reducer.reduce(
      elapsed: 3, role: "host", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: Self.statistics(bytesReceived: 0), mailboxDrops: 0, frameSize: nil)
    let host = RigHUDFormatter.lines(
      sample: sample, role: .host, name: "tuftlord", build: build, peerName: "mac", peerBuild: build, reconnects: 0,
      capture: "workload:1920x1080@60")
    #expect(host[0] == "host tuftlord · abcdef12 release")
    #expect(host[1] == "peer mac · abcdef12 release")
    #expect(host[2] == "connection: connected · reconnects 0 · 3s")
    #expect(host[3] == "source workload:1920x1080@60 · 1920 × 1080 @ 60")
    #expect(host.count == 7)
    let viewer = RigHUDFormatter.lines(
      sample: sample, role: .viewer, name: "mac", build: build, peerName: nil, peerBuild: nil, reconnects: 0,
      capture: nil)
    #expect(viewer.count == 8)
    #expect(viewer[6] == "image age — (clock not calibrated)")
    #expect(viewer[3].contains("rtt 4.0 ms · host/udp→host"))
  }

  @Test func writerAppendsLinesAndRotatesAtTheLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rig-telemetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var reducer = RigTelemetryReducer()
    let sample = reducer.reduce(
      elapsed: 1, role: "viewer", connection: "new", sessionID: nil, snapshot: ScreenSharingMetrics().snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    let line = try RigJSON.encode(sample).count + 1
    let writer = try RigTelemetryWriter(directory: directory, role: "viewer", maximumBytes: line * 2)
    try writer.append(sample)
    try writer.append(sample)
    #expect(try Data(contentsOf: writer.url).count == line * 2)
    try writer.append(sample)
    writer.close()
    let rotated = directory.appendingPathComponent("viewer.1.jsonl")
    #expect(try Data(contentsOf: rotated).count == line * 2)
    let current = try String(contentsOf: writer.url, encoding: .utf8)
    #expect(current.hasSuffix("\n"))
    #expect(current.split(separator: "\n").count == 1)
    #expect(try RigJSON.decode(RigTelemetrySample.self, from: Data(current.dropLast().utf8)) == sample)
  }
}

extension RigTelemetryTests {
  @Test func hudExplainsUnpresentedDrawablesAsOffScreen() {
    var reducer = RigTelemetryReducer()
    let metrics = ScreenSharingMetrics()
    metrics.increment("unpresentedDrawables", by: 10)
    _ = reducer.reduce(
      elapsed: 1, role: "viewer", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    metrics.increment("unpresentedDrawables", by: 60)
    let covered = reducer.reduce(
      elapsed: 2, role: "viewer", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(covered.unpresentedDrawablesPerSecond == 60)
    #expect(covered.presentedFramesPerSecond == nil)
    let build = RigBuildInfo.unknown
    let lines = RigHUDFormatter.lines(
      sample: covered, role: .viewer, name: "mac", build: build, peerName: nil, peerBuild: nil, reconnects: 0,
      capture: nil)
    #expect(lines[2].hasPrefix("presented — (window not on screen)"))
    metrics.increment("presentedFrames", by: 55)
    let shown = reducer.reduce(
      elapsed: 3, role: "viewer", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(shown.presentedFramesPerSecond == nil, "first appearance of the counter has no previous value")
    metrics.increment("presentedFrames", by: 55)
    let steady = reducer.reduce(
      elapsed: 4, role: "viewer", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(steady.presentedFramesPerSecond == 55)
  }
}

extension RigTelemetryTests {
  @Test func stallLabelReachesTheSampleAndTheHostHUD() {
    var reducer = RigTelemetryReducer()
    let metrics = ScreenSharingMetrics()
    metrics.label("sourceStall", "")
    let quiet = reducer.reduce(
      elapsed: 1, role: "host", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(quiet.sourceStall == nil, "an empty label means no stall")
    metrics.label("sourceStall", "no frames 5 s after synthetic started")
    let stalled = reducer.reduce(
      elapsed: 2, role: "host", connection: "connected", sessionID: "s", snapshot: metrics.snapshot(),
      statistics: [:], mailboxDrops: 0, frameSize: nil)
    #expect(stalled.sourceStall == "no frames 5 s after synthetic started")
    let lines = RigHUDFormatter.lines(
      sample: stalled, role: .host, name: "h", build: .unknown, peerName: nil, peerBuild: nil, reconnects: 0,
      capture: "synthetic")
    #expect(lines.count == 6)
    #expect(lines[2].contains("STALL: no frames 5 s after synthetic started"))
  }
}
