import ScreenSharing

struct CodevisorViewResult: Encodable {
  let role = "codevisor-viewer"
  let host: String
  let firstPresentedNs: Int64?
  let timeline: ScreenSharingFrameTimelineSummary?
  let counters: [String: Int]
  let labels: [String: String]
  let mailboxDroppedFrames: Int
  let selectedCandidates: [String: String]
  let inbound: [String: String]

  @MainActor
  init(
    host: String, firstPresentedNs: Int64?, metrics: ScreenSharingMetrics, droppedFrames: Int,
    statistics: [String: String]
  ) {
    let snapshot = metrics.snapshot()
    self.host = host
    self.firstPresentedNs = firstPresentedNs
    timeline = metrics.timeline.summary()
    counters = snapshot.counters
    labels = snapshot.labels
    mailboxDroppedFrames = droppedFrames
    selectedCandidates = statistics.filter { $0.key.contains("candidate") }
    inbound = statistics.filter { $0.key.hasPrefix("inbound-rtp.") || $0.key.hasPrefix("codec.") }
  }
}
