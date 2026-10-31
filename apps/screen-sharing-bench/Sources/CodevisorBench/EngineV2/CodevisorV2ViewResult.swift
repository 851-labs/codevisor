import ScreenSharing

struct CodevisorV2ViewResult: Encodable {
  let role = "codevisor-viewer"
  let engine = "v2"
  let host: String
  let presentation: String
  let timeline: ScreenSharingFrameTimelineSummary?
  let counters: [String: Int]
  let labels: [String: String]
  let timings: [String: ScreenSharingMetrics.Timing]
  let mailboxDroppedFrames: Int
  let media: [String: Double]
  let paths: [String]
  let selectedCandidates: [String: String]

  init(
    host: String, presentation: V2Presentation, metrics: ScreenSharingMetrics, droppedFrames: Int,
    media: [String: Double], paths: [String]
  ) {
    let snapshot = metrics.snapshot()
    self.host = host
    self.presentation = presentation.rawValue
    timeline = metrics.timeline.summary()
    counters = snapshot.counters
    labels = snapshot.labels
    timings = snapshot.timings
    mailboxDroppedFrames = droppedFrames
    self.media = media
    self.paths = paths
    selectedCandidates = ["media.currentRoundTripTime": String((media["rtt_ms"] ?? 0) / 1000)]
  }
}
