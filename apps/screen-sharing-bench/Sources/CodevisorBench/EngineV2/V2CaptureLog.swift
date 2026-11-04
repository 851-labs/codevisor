import CoreGraphics
import ScreenSharing
import Synchronization

final class V2CaptureLog: ScreenSharingFrameSink {
  struct Entry: Encodable {
    let displayNs: Int64
    let callbackNs: Int64
    let dirtyRects: Int?
    let touchesBarcode: Bool
  }

  static let barcodeCorner = CGRect(x: 0, y: 0, width: 640, height: 64)
  static let capacity = 6_000

  private let sink: any ScreenSharingFrameSink
  private let entries = Mutex<[Entry]>([])

  init(forwardingTo sink: any ScreenSharingFrameSink) {
    self.sink = sink
  }

  var recorded: [Entry] { entries.withLock { $0 } }

  func push(_ frame: ScreenSharingVideoFrame) {
    let entry = Entry(
      displayNs: frame.timestampNs, callbackNs: ScreenSharingMetrics.nowNs, dirtyRects: frame.dirtyRects?.count,
      touchesBarcode: frame.dirtyRects.map { $0.contains { $0.intersects(Self.barcodeCorner) } } ?? true)
    entries.withLock { if $0.count < Self.capacity { $0.append(entry) } }
    sink.push(frame)
  }
}
