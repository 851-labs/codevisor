import ScreenSharing
import ScreenSharingV2

struct ShareV2Result: Encodable {
  let role = "codevisor-host"
  let engine = "v2"
  let viewer: String
  let display: ShareDisplay
  let codec = ScreenSharingV2Profile.codec.rawValue
  let captureSize: String
  let encoder: String
  let bitrateCeiling = ScreenSharingV2Profile.bitrateCeiling
  let captureError: String?
  let counters: [String: Int]
  let labels: [String: String]
  let timings: [String: ScreenSharingMetrics.Timing]
  let media: [String: Double]
  let control: BenchHostControlSummary

  init(
    viewer: String, display: ShareDisplay, configuration: ScreenSharingVideoConfiguration,
    encoder: ScreenSharingV2EncoderKind, captureError: (any Error)?,
    metrics: ScreenSharingMetrics.Snapshot, media: [String: Double], control: BenchHostControlSummary
  ) {
    self.viewer = viewer
    self.display = display
    captureSize = "\(configuration.width)x\(configuration.height)"
    self.encoder = encoder.rawValue
    self.captureError = captureError.map { "\($0)" }
    counters = metrics.counters
    labels = metrics.labels
    timings = metrics.timings
    self.media = media
    self.control = control
  }
}
