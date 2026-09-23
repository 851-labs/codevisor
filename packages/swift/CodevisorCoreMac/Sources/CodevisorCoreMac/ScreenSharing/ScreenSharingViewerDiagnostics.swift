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
  /// VNC only: framebuffer updates applied per second.
  public private(set) var updatesPerSecond: Double?
  /// VNC only: mean wire bytes per update over the last interval.
  public private(set) var bytesPerUpdate: Double?
  /// VNC only: p95 from sending an update request to applying its update.
  public private(set) var updateLatencyMilliseconds: Double?
  @ObservationIgnored private var previous: (time: TimeInterval, frames: Int, bytes: Double, updates: Int)?

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
    if let vncTransport {
      let pushed = metrics.labels["vncUpdateMode"] == "continuous"
      route =
        "VNC · \(vncTransport)" + (pushed ? " · continuous" : "")
        + (metrics.labels["vncQuality"].map { " · \($0)" } ?? "")
      updateLatencyMilliseconds = metrics.timings["vncUpdateLatency"]?.p95Ms
      // Fence round trips (851-2312); nil until the server speaks Fence.
      roundTripMilliseconds = metrics.timings["vncRoundTrip"]?.p50Ms
      return
    }
    roundTripMilliseconds = statistics.first { $0.key.hasSuffix(".currentRoundTripTime") }
      .flatMap { Double($0.value) }.map { $0 * 1000 }
    let types = statistics.filter { $0.key.hasSuffix(".candidateType") }.values
    // A TURN allocation may carry UDP media over a TCP/TLS connection to the
    // relay. Report that client transport when the selected candidate exposes it.
    let transport =
      (statistics.first { $0.key.hasSuffix(".relayProtocol") }
      ?? statistics.first { $0.key.hasSuffix(".protocol") })?.value.uppercased() ?? ""
    route =
      types.isEmpty
      ? "Connecting" : (types.contains("relay") ? "Relay" : "Direct") + (transport.isEmpty ? "" : " · " + transport)
    decodeMilliseconds = metrics.timings["decode"]?.p95Ms
  }
}
