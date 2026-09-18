import ScreenSharing
import Foundation

/// The pinned M152 encoder emits these aggregate counts periodically. Retain
/// only the three numeric counters; WebRTC's other logs can contain addresses.
package enum ScreenSharingEncoderDropLog {
  package static func counters(in message: String) -> [String: Int] {
    let prefix = "Number of frames: captured "
    guard let start = message.range(of: prefix) else { return [:] }
    let pieces = message[start.upperBound...].components(separatedBy: ", ")
    guard pieces.count == 4,
      pieces[1].hasPrefix("dropped (due to congestion window pushback) "),
      pieces[2].hasPrefix("dropped (due to encoder blocked) "),
      pieces[3].hasPrefix("interval_ms "),
      let captured = Int(pieces[0]),
      let congestion = pieces[1].split(separator: " ").last.flatMap({ Int($0) }),
      let blocked = pieces[2].split(separator: " ").last.flatMap({ Int($0) }),
      captured >= 0, congestion >= 0, blocked >= 0
    else { return [:] }
    return ["rtcLoggedInputFrames": captured, "rtcCongestionWindowDrops": congestion, "rtcEncoderQueueDrops": blocked]
  }

  /// Pinned M152 encoder-side drop or pause messages, with hexadecimal
  /// addresses removed and length bounded; anything else yields nil.
  package static func dropDiagnostic(in message: String) -> String? {
    let markers = [
      "Same/old NTP timestamp", "encoder is blocked", "Too large for target bitrate", "Drop Frame:",
      "encoder paused", "Video suspended", "Dropping frame",
    ]
    guard markers.contains(where: { message.contains($0) }) else { return nil }
    var sanitized = ""
    var index = message.startIndex
    while index < message.endIndex {
      if message[index...].hasPrefix("0x") {
        var end = message.index(index, offsetBy: 2)
        while end < message.endIndex, message[end].isHexDigit { end = message.index(after: end) }
        sanitized += "0x…"
        index = end
      } else {
        sanitized.append(message[index])
        index = message.index(after: index)
      }
    }
    return String(sanitized.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
  }
}
