import Foundation
@preconcurrency import WebRTC
import ScreenSharing

enum ScreenSharingPeerStatistics {
  /// One native subreport, reduced to what the selection below reads. The
  /// shipped `RTCStatistics` cannot be constructed outside WebRTC, so the
  /// selection is expressed over this shape and tests build report inputs
  /// directly; the native path simply projects each subreport into it.
  struct Entry {
    let id: String
    let type: String
    let values: [String: NSObject]
  }

  static func values(_ report: RTCStatisticsReport) -> [String: String] {
    values(report.statistics.values.map { Entry(id: $0.id, type: $0.type, values: $0.values) })
  }

  static func values(_ entries: [Entry]) -> [String: String] {
    var result: [String: String] = [:]
    let fields = [
      "framesEncoded", "framesDecoded", "framesDropped", "framesPerSecond", "bytesSent", "bytesReceived",
      "packetsLost", "jitter", "currentRoundTripTime", "availableOutgoingBitrate", "encoderImplementation",
      "decoderImplementation", "mimeType", "protocol", "relayProtocol", "candidateType", "state", "nominated",
      "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferMinimumDelay", "jitterBufferEmittedCount",
      "totalDecodeTime", "totalProcessingDelay", "totalEncodeTime", "totalPacketSendDelay", "packetsSent",
      "packetsReceived", "framesReceived", "keyFramesDecoded", "nackCount", "pliCount", "firCount",
      "freezeCount", "totalFreezesDuration", "retransmittedPacketsSent", "qualityLimitationReason",
      "networkType", "retransmittedPacketsReceived", "retransmittedBytesReceived", "rtxSsrc",
      "retransmittedBytesSent", "headerBytesSent", "headerBytesReceived", "fecPacketsReceived",
    ]
    let selectedIDs = Set(
      entries.filter { $0.type == "transport" }
        .compactMap { $0.values["selectedCandidatePairId"] as? String })
    let selectedPairs = entries.filter {
      guard $0.type == "candidate-pair" else { return false }
      if !selectedIDs.isEmpty { return selectedIDs.contains($0.id) }
      return ($0.values["nominated"] as? NSNumber)?.boolValue == true
        && ($0.values["state"] as? String) == "succeeded"
    }
    let candidateIDs = Set(
      selectedPairs.flatMap {
        [$0.values["localCandidateId"] as? String, $0.values["remoteCandidateId"] as? String].compactMap { $0 }
      })
    for statistic in entries {
      if statistic.type == "candidate-pair", !selectedPairs.contains(where: { $0.id == statistic.id }) { continue }
      if ["local-candidate", "remote-candidate"].contains(statistic.type), !candidateIDs.contains(statistic.id) {
        continue
      }
      guard
        ["outbound-rtp", "inbound-rtp", "candidate-pair", "codec", "local-candidate", "remote-candidate"]
          .contains(statistic.type)
      else { continue }
      for field in fields {
        if let value = statistic.values[field] {
          result["\(statistic.type).\(statistic.id).\(field)"] = value.description
        }
      }
    }
    return result
  }
}
