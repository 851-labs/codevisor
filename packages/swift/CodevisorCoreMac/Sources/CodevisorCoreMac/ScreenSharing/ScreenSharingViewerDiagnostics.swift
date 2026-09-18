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
  @ObservationIgnored private var previous: (time: TimeInterval, frames: Int, bytes: Double)?

  func update(metrics: ScreenSharingMetrics.Snapshot, statistics: [String: String], now: TimeInterval) {
    let frames = metrics.counters["presentedFrames", default: 0]
    let bytes = statistics.filter { $0.key.hasPrefix("inbound-rtp.") && $0.key.hasSuffix(".bytesReceived") }
      .values.compactMap(Double.init).reduce(0, +)
    if let previous, now > previous.time {
      let elapsed = now - previous.time
      framesPerSecond = Double(max(0, frames - previous.frames)) / elapsed
      megabitsPerSecond = max(0, bytes - previous.bytes) * 8 / elapsed / 1_000_000
    }
    previous = (now, frames, bytes)
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
    resolution = metrics.labels["videoSize"] ?? resolution
    decoder = metrics.labels["decoder"] ?? decoder
    decodeMilliseconds = metrics.timings["decode"]?.p95Ms
    droppedFrames = metrics.counters["renderDrops", default: 0]
  }
}
