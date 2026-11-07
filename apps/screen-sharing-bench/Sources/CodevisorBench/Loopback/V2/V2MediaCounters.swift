import ScreenSharingBench
import ScreenSharingV2

enum V2MediaCounters {
  static func make(
    host: [String: Int], viewer: [String: Int], hostMedia: [String: Double], viewerMedia: [String: Double],
    hostLabels: [String: String]
  ) -> BenchMediaCounters {
    BenchMediaCounters(
      framesSent: count(hostMedia["frames_sent"]), framesLost: count(hostMedia["frames_lost"]),
      tilesSkipped: viewer["skippedFrames", default: 0],
      droppedBeforeEncode: host["captureReplacedBeforeEncode", default: 0],
      admissionDeferrals: host["admissionDeferrals", default: 0], nacksSent: count(viewerMedia["nacks_sent"]),
      packetsRetransmitted: count(hostMedia["packets_retransmitted"]),
      parityPackets: count(hostMedia["parity_packets_sent"]),
      fecRepairs: viewer["recovered.forwardErrorCorrection", default: 0],
      nackRepairs: viewer["recovered.retransmission", default: 0],
      ltrRefreshes: host["encodedLTRRefreshes", default: 0], keyframes: host["encodedKeyFrames", default: 0],
      capacityKbps: hostMedia["estimate_kbps"].map { Int($0) }, roundTripMs: hostMedia["rtt_ms"],
      requestedRefreshes: host["requestedRefreshes", default: 0],
      requestedKeyframes: host["requestedKeyframes", default: 0], stalledTiles: viewer["stalledTiles", default: 0],
      encodedFrames: host["encodedFrames"], encodedBytes: host["encodedBytes"],
      encodedKeyFrameBytes: host["encodedKeyFrameBytes"], encoderSwitches: host["encoderSwitches"],
      ltrRefreshKeyframes: host["encodedLTRRefreshKeyFrames", default: 0],
      estimateMinMbpsPerSecond: estimateTrace(hostLabels[ScreenSharingV2EstimateTraceLabel.name]))
  }

  private static func estimateTrace(_ label: String?) -> [Double]? {
    guard let label, !label.isEmpty else { return nil }

    let values = label.split(separator: ",").map { $0 == ScreenSharingV2EstimateTraceLabel.gap ? -1 : Double($0) }
    return values.contains(nil) ? nil : values.compactMap(\.self)
  }

  private static func count(_ value: Double?) -> Int {
    Int(value ?? 0)
  }
}
