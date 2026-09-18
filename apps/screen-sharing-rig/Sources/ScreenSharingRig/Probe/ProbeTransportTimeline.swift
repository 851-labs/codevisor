import ScreenSharingDiagnostics
import ScreenSharing

/// Per-second interval means; never present percentiles of these as per-frame p95.
struct ProbeTransportTimeline {
  struct Sample: Encodable {
    let elapsedSeconds: Double
    let senderIntervalMeans: [String: Double]
    let receiverIntervalMeans: [String: Double]
    let senderRTC: [String: String]
    let receiverRTC: [String: String]
  }
  private var sender = ScreenSharingRTCIntervalMetrics()
  private var receiver = ScreenSharingRTCIntervalMetrics()
  private(set) var samples: [Sample] = []

  mutating func append(elapsed: Double, sender sent: [String: String], receiver received: [String: String]) {
    guard samples.count < 3602 else { return }
    samples.append(
      Sample(
        elapsedSeconds: elapsed, senderIntervalMeans: sender.update(sent),
        receiverIntervalMeans: receiver.update(received), senderRTC: sent, receiverRTC: received))
  }
}
