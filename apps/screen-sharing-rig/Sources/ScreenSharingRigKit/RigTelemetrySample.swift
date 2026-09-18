import ScreenSharingDiagnostics
import ScreenSharing
import Foundation

/// One per-second view of a session, derived from the process's own metrics
/// and WebRTC statistics. Rates are deltas over the previous sample; no remote
/// clock is subtracted anywhere.
public struct RigTelemetrySample: Codable, Equatable, Sendable {
  public let elapsedSeconds: Double
  public let role: String
  public let connection: String
  public let sessionID: String?
  public let presentedFramesPerSecond: Double?
  /// Drawables whose presented time was zero: rendered, but not shown, as when the window is covered.
  public let unpresentedDrawablesPerSecond: Double?
  public let capturedFramesPerSecond: Double?
  public let encodedFramesPerSecond: Double?
  public let decodedFramesPerSecond: Double?
  public let receiveMegabitsPerSecond: Double?
  public let sendMegabitsPerSecond: Double?
  public let roundTripMilliseconds: Double?
  public let jitterBufferMeanMilliseconds: Double?
  public let decodeMeanMilliseconds: Double?
  public let encodeP95Milliseconds: Double?
  public let submissionToPresentationP95Milliseconds: Double?
  public let callbackToPresentationP95Milliseconds: Double?
  public let mailboxDrops: Int
  public let renderDrops: Int
  public let encodeErrors: Int
  public let decodeErrors: Int
  public let keyFramesDecoded: Int?
  public let nackCount: Int?
  public let pliCount: Int?
  public let candidatePair: String?
  public let availableOutgoingKilobits: Double?
  public let qualityLimitation: String?
  public let captureSize: String?
  public let captureFPS: String?
  public let frameSize: String?
  /// Set when a source started but produced no frames; empty otherwise.
  public let sourceStall: String?
  /// Viewer: capture-to-presentation age of frames shown this interval, from the calibrated clock offset.
  public let imageAge: RigImageAge.Summary?
  /// Viewer: half-width of the clock offset interval; every image age carries this uncertainty.
  public let clockErrorMilliseconds: Double?
  public let counters: [String: Int]
  public let timingsP95: [String: Double]
}

/// Turns raw snapshots into samples. Keeps the previous counters to compute
/// rates; reset it when a new session starts so rates never span sessions.
public struct RigTelemetryReducer: Sendable {
  private var previousElapsed: Double?
  private var previousCounters: [String: Int] = [:]
  private var previousBytesReceived: Double?
  private var previousBytesSent: Double?
  private var interval = ScreenSharingRTCIntervalMetrics()

  public init() {}

  public mutating func reset() {
    previousElapsed = nil
    previousCounters = [:]
    previousBytesReceived = nil
    previousBytesSent = nil
    interval = ScreenSharingRTCIntervalMetrics()
  }

  public mutating func reduce(
    elapsed: Double, role: String, connection: String, sessionID: String?,
    snapshot: ScreenSharingMetrics.Snapshot, statistics: [String: String], mailboxDrops: Int, frameSize: String?,
    imageAge: RigImageAge.Summary? = nil, clockErrorMilliseconds: Double? = nil
  ) -> RigTelemetrySample {
    let means = interval.update(statistics)
    let interval = previousElapsed.map { elapsed - $0 } ?? 0
    func rate(_ counter: String) -> Double? {
      guard interval > 0, let previous = previousCounters[counter] else { return nil }
      return Double(snapshot.counters[counter, default: 0] - previous) / interval
    }
    func number(_ type: String, _ field: String) -> Double? {
      Self.statistic(statistics, type: type, field: field).flatMap(Double.init)
    }
    func megabits(_ current: Double?, previous: Double?) -> Double? {
      guard interval > 0, let current, let previous, current >= previous else { return nil }
      return (current - previous) * 8 / interval / 1_000_000
    }
    let bytesReceived = number("inbound-rtp", "bytesReceived")
    let bytesSent = number("outbound-rtp", "bytesSent")
    let localType = Self.statistic(statistics, type: "local-candidate", field: "candidateType")
    let localProtocol = Self.statistic(statistics, type: "local-candidate", field: "protocol")
    let remoteType = Self.statistic(statistics, type: "remote-candidate", field: "candidateType")
    let pair = localType.map { "\($0)/\(localProtocol ?? "?")→\(remoteType ?? "?")" }
    let sample = RigTelemetrySample(
      elapsedSeconds: elapsed, role: role, connection: connection, sessionID: sessionID,
      presentedFramesPerSecond: rate("presentedFrames"), unpresentedDrawablesPerSecond: rate("unpresentedDrawables"),
      capturedFramesPerSecond: rate("capturedFrames"),
      encodedFramesPerSecond: rate("encodedFrames"), decodedFramesPerSecond: rate("decodedFrames"),
      receiveMegabitsPerSecond: megabits(bytesReceived, previous: previousBytesReceived),
      sendMegabitsPerSecond: megabits(bytesSent, previous: previousBytesSent),
      roundTripMilliseconds: number("candidate-pair", "currentRoundTripTime").map { $0 * 1000 },
      jitterBufferMeanMilliseconds: means["jitterBufferMeanMs"], decodeMeanMilliseconds: means["rtcDecodeMeanMs"],
      encodeP95Milliseconds: snapshot.timings["encode"]?.p95Ms,
      submissionToPresentationP95Milliseconds: snapshot.timings["submissionToPresentation"]?.p95Ms,
      callbackToPresentationP95Milliseconds: snapshot.timings["receiverCallbackToPresentation"]?.p95Ms,
      mailboxDrops: mailboxDrops, renderDrops: snapshot.counters["renderDrops", default: 0],
      encodeErrors: snapshot.counters["encodeErrors", default: 0],
      decodeErrors: snapshot.counters["decodeErrors", default: 0],
      keyFramesDecoded: number("inbound-rtp", "keyFramesDecoded").map(Int.init),
      nackCount: (number("inbound-rtp", "nackCount") ?? number("outbound-rtp", "nackCount")).map(Int.init),
      pliCount: (number("inbound-rtp", "pliCount") ?? number("outbound-rtp", "pliCount")).map(Int.init),
      candidatePair: pair,
      availableOutgoingKilobits: number("candidate-pair", "availableOutgoingBitrate").map { $0 / 1000 },
      qualityLimitation: Self.statistic(statistics, type: "outbound-rtp", field: "qualityLimitationReason"),
      captureSize: snapshot.labels["captureSize"], captureFPS: snapshot.labels["captureFPS"], frameSize: frameSize,
      sourceStall: snapshot.labels["sourceStall"].flatMap { $0.isEmpty ? nil : $0 },
      imageAge: imageAge, clockErrorMilliseconds: clockErrorMilliseconds,
      counters: snapshot.counters, timingsP95: snapshot.timings.mapValues(\.p95Ms))
    previousElapsed = elapsed
    previousCounters = snapshot.counters
    previousBytesReceived = bytesReceived
    previousBytesSent = bytesSent
    return sample
  }

  /// Statistics keys are `type.id.field`; the peer already filters to the
  /// selected candidate pair, so the first match is the one that matters.
  public static func statistic(_ statistics: [String: String], type: String, field: String) -> String? {
    let prefix = type + "."
    let suffix = "." + field
    return statistics.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted().first.flatMap {
      statistics[$0]
    }
  }
}

/// Fixed-width lines for the on-screen HUD. Pure so the layout is testable.
