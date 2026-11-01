import Foundation
@preconcurrency import WebRTC
import ScreenSharing

struct ScreenSharingInboundVideo: Sendable {
  let transport: ScreenSharingPeerTransport

  func bytesReceived() async -> Int64? {
    let bytes: Int64?? = try? await transport.call { connection, done in
      guard let receiver = connection.transceivers.first(where: { $0.mediaType == .video })?.receiver else {
        done(.success(nil))
        return
      }
      connection.statistics(for: receiver) { report in
        done(.success(Self.bytesReceived(in: ScreenSharingPeerStatistics.entries(report))))
      }
    }
    return bytes ?? nil
  }

  static func bytesReceived(in entries: [ScreenSharingPeerStatistics.Entry]) -> Int64? {
    let counters = entries.filter { $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video" }
      .flatMap { [$0.values["bytesReceived"], $0.values["retransmittedBytesReceived"]] }
      .compactMap { ($0 as? NSNumber)?.int64Value }
    guard !counters.isEmpty else { return nil }
    return counters.reduce(0, +)
  }
}
