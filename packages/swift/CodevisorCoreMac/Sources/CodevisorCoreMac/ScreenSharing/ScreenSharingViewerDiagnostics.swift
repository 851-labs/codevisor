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

  func update(metrics: ScreenSharingMetrics.Snapshot, statistics: [String: String], now: TimeInterval) {
    let vncTransport = statistics["vnc.transport"]
    let frames = metrics.counters["presentedFrames", default: 0]
    let updates = metrics.counters["vncUpdatesPublished", default: 0]
    let bytes =
      vncTransport != nil
      ? Double(metrics.counters["vncBytesReceived", default: 0])
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
