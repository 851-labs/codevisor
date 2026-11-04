import CoreGraphics
import CoreVideo
import ScreenSharing
import Synchronization
import Testing

@testable import CodevisorBench

struct V2CaptureLogTests {
  private final class Collector: ScreenSharingFrameSink {
    let pushed = Mutex<[Int64]>([])
    func push(_ frame: ScreenSharingVideoFrame) { pushed.withLock { $0.append(frame.timestampNs) } }
  }

  @Test func forwardsEveryCaptureAndMarksTheOnesThatTouchTheBarcodeCorner() throws {
    let collector = Collector()
    let log = V2CaptureLog(forwardingTo: collector)

    log.push(try frame(at: 1, dirty: [CGRect(x: 10, y: 10, width: 32, height: 32)]))
    log.push(try frame(at: 2, dirty: [CGRect(x: 1000, y: 900, width: 40, height: 40)]))
    log.push(try frame(at: 3, dirty: nil))

    #expect(collector.pushed.withLock { $0 } == [1, 2, 3])
    #expect(log.recorded.map(\.displayNs) == [1, 2, 3])
    #expect(log.recorded.map(\.touchesBarcode) == [true, false, true])
    #expect(log.recorded.map(\.dirtyRects) == [1, 1, nil])
  }

  private func frame(at timestampNs: Int64, dirty: [CGRect]?) throws -> ScreenSharingVideoFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
    return ScreenSharingVideoFrame(pixelBuffer: try #require(buffer), timestampNs: timestampNs, dirtyRects: dirty)
  }
}
