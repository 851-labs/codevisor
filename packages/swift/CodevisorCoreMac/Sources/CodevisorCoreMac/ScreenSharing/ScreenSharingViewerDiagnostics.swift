import ScreenSharing
import Foundation
import Observation

@MainActor
@Observable
public final class ScreenSharingViewerDiagnostics {
  public private(set) var framesPerSecond: Double?
  public private(set) var megabitsPerSecond: Double?
  public private(set) var roundTripMilliseconds: Double?
  public private(set) var route = "Connecting"
  public private(set) var resolution = "Waiting for video"
  public private(set) var decoder = "Waiting for decoder"
  public private(set) var decodeMilliseconds: Double?
  public private(set) var droppedFrames = 0
  public private(set) var streams: String?
  public private(set) var updatesPerSecond: Double?
  public private(set) var bytesPerUpdate: Double?
  public private(set) var updateLatencyMilliseconds: Double?
  public private(set) var engine: String?
  public private(set) var recovery: String?
  @ObservationIgnored private var previous: (time: TimeInterval, frames: Int, bytes: Double, updates: Int)?

  static func streams(_ labels: [String: String]) -> String? {
    let parts = [
      labels["pointer"].map { "pointer \($0)" },
      labels["audioTargetDelayMs"].map { "sound \($0) ms behind" },
      labels["desktopResize"].map { "display \($0)" },
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  nonisolated static func webRTCRoute(candidateTypes: some Collection<String>, transport: String) -> String {
    guard !candidateTypes.isEmpty else { return "Connecting" }
    let path = candidateTypes.contains("relay") ? "Relay" : "Direct"
    return path + (transport.isEmpty ? "" : " · " + transport)
  }

  static func v2Recovery(_ statistics: [String: String]) -> String? {
    guard let loss = statistics["v2.lossPercent"].flatMap(Double.init) else { return nil }

    let nacks = statistics["v2.nacksSent"] ?? "0"
    let repaired = statistics["v2.recoveredByFEC"] ?? "0"
    let skipped = statistics["v2.framesSkipped"] ?? "0"
    return String(format: "%.1f%% loss", loss) + " · \(nacks) NACK · \(repaired) FEC · \(skipped) skipped"
  }

  private func updateV2(metrics: ScreenSharingMetrics.Snapshot, statistics: [String: String]) {
    engine = "v2 · QUIC"
    route = statistics["v2.route"] == "relay" ? "Relay" : statistics["v2.route"] == nil ? "Connecting" : "Direct"
    roundTripMilliseconds = statistics["v2.roundTripMs"].flatMap(Double.init)
    decodeMilliseconds = metrics.timings["decode"]?.p95Ms
    recovery = Self.v2Recovery(statistics)
  }

  func update(metrics: ScreenSharingMetrics.Snapshot, statistics: [String: String], now: TimeInterval) {
    let vncTransport = statistics["vnc.transport"]
    let v2 = statistics["v2.engine"] != nil
    let frames = metrics.counters["presentedFrames", default: 0]
    let updates = metrics.counters["vncUpdatesPublished", default: 0]
    let bytes =
      vncTransport != nil
      ? Double(metrics.counters["vncBytesReceived", default: 0])
      : v2
        ? statistics["v2.bytesReceived"].flatMap(Double.init) ?? 0
        : statistics.filter { $0.key.hasPrefix("inbound-rtp.") && $0.key.hasSuffix(".bytesReceived") }
          .values.compactMap(Double.init).reduce(0, +)
    if let previous, now > previous.time {
      let elapsed = now - previous.time
      framesPerSecond = Double(max(0, frames - previous.frames)) / elapsed
      megabitsPerSecond = max(0, bytes - previous.bytes) * 8 / elapsed / 1_000_000
      if vncTransport != nil {
        let applied = max(0, updates - previous.updates)
        updatesPerSecond = Double(applied) / elapsed
        bytesPerUpdate = applied > 0 ? max(0, bytes - previous.bytes) / Double(applied) : nil
      }
    }
    previous = (now, frames, bytes, updates)
    resolution = metrics.labels["videoSize"] ?? resolution
    decoder = metrics.labels["decoder"] ?? decoder
    droppedFrames = metrics.counters["renderDrops", default: 0]
    streams = Self.streams(metrics.labels)
    if v2 { return updateV2(metrics: metrics, statistics: statistics) }
    if let vncTransport {
      let pushed = metrics.labels["vncUpdateMode"] == "continuous"
      route =
        "VNC · \(vncTransport)" + (pushed ? " · continuous" : "")
        + (metrics.labels["vncQuality"].map { " · \($0)" } ?? "")
      updateLatencyMilliseconds = metrics.timings["vncUpdateLatency"]?.p95Ms
      roundTripMilliseconds = metrics.timings["vncRoundTrip"]?.p50Ms
      return
    }
    roundTripMilliseconds = statistics.first { $0.key.hasSuffix(".currentRoundTripTime") }
      .flatMap { Double($0.value) }.map { $0 * 1000 }
    let types = statistics.filter { $0.key.hasSuffix(".candidateType") }.values
    let transport =
      (statistics.first { $0.key.hasSuffix(".relayProtocol") }
      ?? statistics.first { $0.key.hasSuffix(".protocol") })?.value.uppercased() ?? ""
    route = Self.webRTCRoute(candidateTypes: types, transport: transport)
    decodeMilliseconds = metrics.timings["decode"]?.p95Ms
  }
}
