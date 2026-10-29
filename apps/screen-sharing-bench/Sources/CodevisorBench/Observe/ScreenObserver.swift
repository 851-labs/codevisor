import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import ScreenSharingBench

@MainActor
final class ScreenObserver {
  private static let maximumFrameRate: Int32 = 240
  private static let queueDepth = 8

  let source: String
  private let stream: SCStream
  private let collector: FrameCollector

  private init(stream: SCStream, collector: FrameCollector, source: String) {
    self.stream = stream
    self.collector = collector
    self.source = source
  }

  static func start(
    display: SCDisplay, region: ObserverRegion, layout: BenchBarcodeLayout
  ) async throws -> ScreenObserver {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = CGFloat(filter.pointPixelScale)
    let collector = FrameCollector(layout: capturedLayout(layout, region: region))
    let stream = SCStream(
      filter: filter, configuration: configuration(display, region, layout, scale), delegate: collector)
    try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: collector.queue)
    try await stream.startCapture()
    return ScreenObserver(stream: stream, collector: collector, source: describe(display, region, layout))
  }

  static func display(id: CGDirectDisplayID?) async throws -> SCDisplay {
    try PlayerConsoleSession.requireUnlocked()
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let wanted = id ?? CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == wanted }) else {
      throw BenchUsageError(message: "no display \(wanted); displays: \(content.displays.map(\.displayID))")
    }

    return display
  }

  var continuousMinusAbsoluteNs: Int64 {
    collector.continuousMinusAbsoluteNs
  }

  func stop() async throws -> [BenchObservation] {
    do {
      try await stream.stopCapture()
    } catch {
      _ = try collector.collected()
      throw error
    }
    return try collector.collected()
  }

  private static func configuration(
    _ display: SCDisplay, _ region: ObserverRegion, _ layout: BenchBarcodeLayout, _ scale: CGFloat
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.queueDepth = queueDepth
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: maximumFrameRate)
    switch region {
    case .barcode:
      configuration.sourceRect = CGRect(
        x: CGFloat(layout.x) / scale, y: CGFloat(layout.y) / scale, width: CGFloat(layout.width) / scale,
        height: CGFloat(layout.height) / scale)
      configuration.width = layout.width
      configuration.height = layout.height
    case .full:
      configuration.width = Int(CGFloat(display.width) * scale)
      configuration.height = Int(CGFloat(display.height) * scale)
    }
    return configuration
  }

  private static func capturedLayout(_ layout: BenchBarcodeLayout, region: ObserverRegion) -> BenchBarcodeLayout {
    switch region {
    case .barcode: BenchBarcodeLayout(blockSize: layout.blockSize)
    case .full: layout
    }
  }

  private static func describe(_ display: SCDisplay, _ region: ObserverRegion, _ layout: BenchBarcodeLayout) -> String {
    "display \(display.displayID) \(display.width)x\(display.height) pt, \(region.rawValue) region, barcode at "
      + "\(layout.x),\(layout.y) px with \(layout.blockSize) px blocks"
  }
}
