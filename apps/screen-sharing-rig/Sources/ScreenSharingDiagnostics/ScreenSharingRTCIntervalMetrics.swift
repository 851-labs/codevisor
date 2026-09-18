import ScreenSharing
import Foundation

/// W3C cumulative seconds/count pairs become weighted interval means, not
/// per-frame percentiles. Baseline each stream independently across resets.
package struct ScreenSharingRTCIntervalMetrics: Sendable {
  private var previous: [String: String] = [:]
  package init() {}

  package mutating func update(_ statistics: [String: String]) -> [String: Double] {
    defer { previous = statistics }
    let pairs = [
      ("inbound-rtp", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferMeanMs"),
      ("inbound-rtp", "jitterBufferTargetDelay", "jitterBufferEmittedCount", "jitterBufferTargetMeanMs"),
      ("inbound-rtp", "jitterBufferMinimumDelay", "jitterBufferEmittedCount", "jitterBufferMinimumMeanMs"),
      ("inbound-rtp", "totalDecodeTime", "framesDecoded", "rtcDecodeMeanMs"),
      ("inbound-rtp", "totalProcessingDelay", "framesDecoded", "receiveToDecodeMeanMs"),
      ("outbound-rtp", "totalEncodeTime", "framesEncoded", "rtcEncodeMeanMs"),
      ("outbound-rtp", "totalPacketSendDelay", "packetsSent", "packetSendDelayMeanMs"),
    ]
    var result: [String: Double] = [:]
    func number(_ values: [String: String], _ key: String) -> Double? {
      guard let raw = values[key], let value = Double(raw), value.isFinite, value >= 0 else { return nil }
      return value
    }
    for (type, total, count, name) in pairs {
      var seconds = 0.0
      var observations = 0.0
      for key in statistics.keys where key.hasPrefix(type + ".") && key.hasSuffix("." + total) {
        let countKey = String(key.dropLast(total.count)) + count
        guard let currentTotal = number(statistics, key), let oldTotal = number(previous, key),
          let currentCount = number(statistics, countKey), let oldCount = number(previous, countKey),
          currentTotal >= oldTotal, currentCount > oldCount
        else { continue }
        seconds += currentTotal - oldTotal
        observations += currentCount - oldCount
      }
      if observations > 0 { result[name] = seconds / observations * 1000 }
    }
    return result
  }
}
