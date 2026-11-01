import CodevisorNet

enum V2MediaStatistics {
  static func dictionary(_ stats: MediaSessionStats) -> [String: Double] {
    [
      "frames_sent": Double(stats.framesSent), "frames_acked": Double(stats.framesAcked),
      "frames_lost": Double(stats.framesLost), "packets_sent": Double(stats.packetsSent),
      "bytes_sent": Double(stats.bytesSent), "parity_packets_sent": Double(stats.parityPacketsSent),
      "packets_retransmitted": Double(stats.packetsRetransmitted), "frames_received": Double(stats.framesReceived),
      "frames_skipped": Double(stats.framesSkipped), "bytes_received": Double(stats.bytesReceived),
      "fec_recoveries": Double(stats.fecRecoveries), "nacks_sent": Double(stats.nacksSent),
      "rtt_ms": Double(stats.rttUs) / 1000, "estimate_kbps": Double(stats.estimateKbps),
      "queue_delay_ms": Double(stats.queueDelayUs) / 1000, "fec_percent": stats.fecPercent,
      "loss_percent": stats.lossPercent,
    ]
  }
}
