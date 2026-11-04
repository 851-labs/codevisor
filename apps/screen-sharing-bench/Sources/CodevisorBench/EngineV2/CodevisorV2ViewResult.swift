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
  let mailboxSupersededChanges: Int
  let media: [String: Double]
  let paths: [String]
  let selectedCandidates: [String: String]
  let control: BenchViewerControlSummary?

  init(
    host: String, presentation: V2Presentation, metrics: ScreenSharingMetrics, droppedFrames: Int,
    supersededChanges: Int, media: [String: Double], paths: [String], control: BenchViewerControlSummary?
  ) {
    let snapshot = metrics.snapshot()
    self.host = host
    self.presentation = presentation.rawValue
    timeline = metrics.timeline.summary()
    counters = snapshot.counters
    labels = snapshot.labels
    timings = snapshot.timings
    mailboxDroppedFrames = droppedFrames
    mailboxSupersededChanges = supersededChanges
    self.media = media
    self.paths = paths
    selectedCandidates = ["media.currentRoundTripTime": String((media["rtt_ms"] ?? 0) / 1000)]
    self.control = control
  }
}
