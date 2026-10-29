import ScreenSharing
import ScreenSharingBench

@MainActor
final class LoopbackInstruments {
  struct Readings {
    let records: [ScreenSharingFrameRecord]
    let barcodes: [Int64: Int?]
    let timingFrames: Set<BenchTimingFrame>
    let qualityLevel: Int
  }

  private let peers: LoopbackPeers
  private let viewer: any LoopbackViewer
  private let verifier: BarcodeVerifier
  private let timeline: TimelineCollector
  private let quality = LoopbackQuality()
  private let sampler = TimingFrameSampler()

  init(peers: LoopbackPeers, viewer: any LoopbackViewer, canvasWidth: Int) {
    self.peers = peers
    self.viewer = viewer
    verifier = BarcodeVerifier(mailbox: peers.receiver.mailbox, canvasWidth: canvasWidth)
    timeline = TimelineCollector(peers.viewerMetrics.timeline)
  }

  func start(source: any LoopbackSource, configuration: ScreenSharingVideoConfiguration, warmUp: Duration) {
    timeline.start()
    quality.start(sender: peers.sender, source: source, configuration: configuration)
    sampler.start(peers.receiver, after: warmUp)
  }

  func stop() -> Readings {
    quality.stop()
    sampler.stop()
    viewer.stop()
    return Readings(
      records: timeline.stop(), barcodes: verifier.stop(), timingFrames: sampler.frames,
      qualityLevel: quality.highestLevel)
  }
}
