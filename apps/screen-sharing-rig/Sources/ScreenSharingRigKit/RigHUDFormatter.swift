import ScreenSharing
import Foundation

public enum RigHUDFormatter {
  public static func lines(
    sample: RigTelemetrySample?, role: RigConfiguration.Role, name: String, build: RigBuildInfo,
    peerName: String?, peerBuild: RigBuildInfo?, reconnects: Int, capture: String?, tuning: String? = nil
  ) -> [String] {
    var lines = ["\(role.rawValue) \(name) · \(build.label)" + (tuning.map { " · tuning: \($0)" } ?? "")]
    if let peerName { lines.append("peer \(peerName) · \(peerBuild?.label ?? "?")") }
    guard let sample else {
      lines.append("connection: waiting · reconnects \(reconnects)")
      return lines
    }
    lines.append("connection: \(sample.connection) · reconnects \(reconnects) · \(format(sample.elapsedSeconds, 0))s")
    switch role {
    case .viewer:
      let presented =
        sample.presentedFramesPerSecond == nil && (sample.unpresentedDrawablesPerSecond ?? 0) > 0
        ? "presented — (window not on screen)" : "presented \(fps(sample.presentedFramesPerSecond))"
      lines.append(
        "\(presented) · decoded \(fps(sample.decodedFramesPerSecond)) · \(sample.frameSize ?? "—")"
      )
      lines.append(
        "rx \(format(sample.receiveMegabitsPerSecond, 1)) Mb/s · rtt \(format(sample.roundTripMilliseconds, 1)) ms · \(sample.candidatePair ?? "—")"
      )
      lines.append(
        "jitter buf \(format(sample.jitterBufferMeanMilliseconds, 1)) ms · decode \(format(sample.decodeMeanMilliseconds, 2)) ms"
      )
      lines.append(
        "present p95 \(format(sample.submissionToPresentationP95Milliseconds, 1)) ms · cb→present p95 \(format(sample.callbackToPresentationP95Milliseconds, 1)) ms"
      )
      if let age = sample.imageAge {
        lines.append(
          "image age p50 \(format(age.p50Milliseconds, 1)) · p95 \(format(age.p95Milliseconds, 1)) · max \(format(age.maximumMilliseconds, 1)) ms ± \(format(sample.clockErrorMilliseconds, 2)) (\(age.count) frames)"
        )
      } else {
        lines.append(
          sample.clockErrorMilliseconds == nil
            ? "image age — (clock not calibrated)" : "image age — (no frames presented this second)")
      }
      lines.append(
        "drops mailbox \(sample.mailboxDrops) render \(sample.renderDrops) · key \(sample.keyFramesDecoded.map(String.init) ?? "—") nack \(sample.nackCount.map(String.init) ?? "—") pli \(sample.pliCount.map(String.init) ?? "—") · decode errors \(sample.decodeErrors)"
      )
    case .host:
      lines.append(
        "source \(capture ?? "—") · \(sample.captureSize ?? "—") @ \(sample.captureFPS ?? "—")"
          + (sample.sourceStall.map { " · STALL: \($0)" } ?? ""))
      lines.append(
        "captured \(fps(sample.capturedFramesPerSecond)) · encoded \(fps(sample.encodedFramesPerSecond)) · encode p95 \(format(sample.encodeP95Milliseconds, 1)) ms"
      )
      lines.append(
        "tx \(format(sample.sendMegabitsPerSecond, 1)) Mb/s · bwe \(format(sample.availableOutgoingKilobits.map { $0 / 1000 }, 1)) Mb/s · rtt \(format(sample.roundTripMilliseconds, 1)) ms"
      )
      lines.append(
        "limit \(sample.qualityLimitation ?? "—") · \(sample.candidatePair ?? "—") · encode errors \(sample.encodeErrors)"
      )
    }
    return lines
  }

  static func fps(_ value: Double?) -> String { value.map { String(format: "%.1f fps", $0) } ?? "— fps" }
  static func format(_ value: Double?, _ decimals: Int) -> String {
    value.map { String(format: "%.\(decimals)f", $0) } ?? "—"
  }
}

/// Appends one JSON line per sample to `<directory>/<role>.jsonl`, rotating
/// to `.1` when the file would exceed the limit. Never contains SDP,
/// addresses or credentials: samples carry only counters and rates.
