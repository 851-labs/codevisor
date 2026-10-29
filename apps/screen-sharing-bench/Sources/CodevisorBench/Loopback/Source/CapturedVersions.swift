import Foundation
import ScreenSharing
import ScreenSharingBench

final class CapturedVersions: ScreenSharingFrameSink, @unchecked Sendable {
  private let sink: any ScreenSharingFrameSink
  private let canvasWidth: Int
  private let lock = NSLock()
  private var events: [BenchVersionEvent] = []

  init(forwardingTo sink: any ScreenSharingFrameSink, canvasWidth: Int) {
    self.sink = sink
    self.canvasWidth = canvasWidth
  }

  var produced: [BenchVersionEvent] {
    lock.withLock { events }
  }

  func push(_ frame: ScreenSharingVideoFrame) {
    sink.push(frame)
    guard let version = LoopbackBarcode.version(in: frame.pixelBuffer, canvasWidth: canvasWidth) else { return }

    record(BenchVersionEvent(version: version, ns: frame.timestampNs))
  }

  private func record(_ event: BenchVersionEvent) {
    lock.withLock {
      guard events.last?.version != event.version else { return }

      events.append(event)
    }
  }
}
