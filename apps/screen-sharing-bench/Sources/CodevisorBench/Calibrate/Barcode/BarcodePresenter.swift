import QuartzCore
import ScreenSharing
import ScreenSharingBench

@MainActor
final class BarcodePresenter {
  private static let bufferCount = 8

  private let view: ScreenSharingMetalView
  private let layout: BenchBarcodeLayout
  private let buffers: [CVPixelBuffer]
  private var lastVersion = 0
  private var lastSequence: UInt64 = 0
  private(set) var versionsBySourceTimestamp: [Int64: Int] = [:]
  private(set) var records: [ScreenSharingFrameRecord] = []

  init(window: BarcodeWindow, layout: BenchBarcodeLayout) throws {
    view = window.view
    self.layout = layout
    buffers = try BarcodePixelBuffers.make(
      count: Self.bufferCount, width: Int(window.pixelSize.width), height: Int(window.pixelSize.height))
  }

  func presentNextVersion() throws {
    lastVersion += 1
    let buffer = buffers[lastVersion % buffers.count]
    try BenchBarcode.draw(lastVersion, into: buffer, layout: layout)
    let nowNs = ScreenSharingMetrics.nowNs
    versionsBySourceTimestamp[nowNs] = lastVersion
    view.metrics.timeline.decoded(
      ScreenSharingDecodedFrameTiming(
        sourceTimestampNs: nowNs, host: nil, decodeInputNs: nowNs, decodeSubmitNs: nowNs, decodedNs: nowNs,
        isKeyFrame: false))
    view.mailbox.put(
      ScreenSharingVideoFrame(
        pixelBuffer: buffer, timestampNs: nowNs, receivedAtSeconds: CACurrentMediaTime(), sourceTimestampNs: nowNs))
    drainRecords()
  }

  func drainRecords() {
    let new = view.metrics.timeline.records(after: lastSequence)
    records += new
    lastSequence = new.last?.sequence ?? lastSequence
  }
}
