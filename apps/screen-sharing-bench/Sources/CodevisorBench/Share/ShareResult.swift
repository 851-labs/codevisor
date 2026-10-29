import ScreenSharing

struct ShareResult: Encodable {
  let role = "codevisor-host"
  let viewer: String
  let codec: String?
  let captureSize: String
  let bitrateCeiling: Int
  let connectedNs: Int64?
  let captureError: String?
  let counters: [String: Int]
  let labels: [String: String]
  let selectedCandidates: [String: String]

  init(
    viewer: String, codec: ScreenSharingVideoCodec?, configuration: ScreenSharingVideoConfiguration,
    connectedNs: Int64?, captureError: (any Error)?, metrics: ScreenSharingMetrics.Snapshot,
    statistics: [String: String]
  ) {
    self.viewer = viewer
    self.codec = codec?.rawValue
    captureSize = "\(configuration.width)x\(configuration.height)"
    bitrateCeiling = configuration.bitrate
    self.connectedNs = connectedNs
    self.captureError = captureError.map { "\($0)" }
    counters = metrics.counters
    labels = metrics.labels
    selectedCandidates = statistics.filter { $0.key.contains("candidate") }
  }
}
