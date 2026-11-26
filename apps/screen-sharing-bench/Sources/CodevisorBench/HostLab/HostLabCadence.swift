import ScreenSharing
import Synchronization

final class HostLabCadence: ScreenSharingFrameSink {
  static let shortBelowMs = 12.5
  static let gapAboveMs = 25.0

  private let sink: any ScreenSharingFrameSink
  private let metrics: ScreenSharingMetrics
  private let last = Mutex<Stamp?>(nil)

  private struct Stamp {
    let displayNs: Int64
    let callbackNs: Int64
  }

  init(forwardingTo sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics) {
    self.sink = sink
    self.metrics = metrics
  }

  func push(_ frame: ScreenSharingVideoFrame) {
    let stamp = Stamp(displayNs: frame.timestampNs, callbackNs: ScreenSharingMetrics.nowNs)
    let previous = last.withLock { value in
      defer { value = stamp }
      return value
    }
    if let previous { record(from: previous, to: stamp) }
    sink.push(frame)
  }

  private func record(from previous: Stamp, to stamp: Stamp) {
    let displayMs = Double(stamp.displayNs - previous.displayNs) / 1_000_000
    metrics.observe("captureDisplayInterval", milliseconds: displayMs)
    metrics.observe("captureCallbackInterval", milliseconds: Double(stamp.callbackNs - previous.callbackNs) / 1_000_000)
    if displayMs < Self.shortBelowMs { metrics.increment("captureIntervalsShort") }
    if displayMs > Self.gapAboveMs { metrics.increment("captureIntervalsGap") }
  }
}
