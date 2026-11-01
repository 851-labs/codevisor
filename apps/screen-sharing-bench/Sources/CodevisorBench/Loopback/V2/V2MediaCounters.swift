import ScreenSharingBench

enum V2MediaCounters {
  static func make(
    host: [String: Int], viewer: [String: Int], hostMedia: [String: Double], viewerMedia: [String: Double]
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
      capacityKbps: hostMedia["estimate_kbps"].map { Int($0) }, roundTripMs: hostMedia["rtt_ms"])
  }

  private static func count(_ value: Double?) -> Int {
    Int(value ?? 0)
  }
}
