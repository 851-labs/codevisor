import Foundation
import ScreenSharing

final class ScreenSharingV2Decoders: @unchecked Sendable {
  private let metrics: ScreenSharingMetrics
  private let lock = NSLock()
  private var decoders: [UInt8: ScreenSharingV2Decoder] = [:]
  private var queues: [UInt8: DispatchQueue] = [:]
  private var stopped = false

  init(metrics: ScreenSharingMetrics) {
    self.metrics = metrics
  }

  func decode(
    _ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64,
    output: @escaping @Sendable (ScreenSharingV2DecodeResult) -> Void
  ) throws {
    try decoder(for: frame.stream).decode(frame, meta: meta, receivedNs: receivedNs, output: output)
  }

  func enqueue(stream: UInt8, _ work: @escaping @Sendable () -> Void) {
    let queue = lock.withLock {
      if let queue = queues[stream] { return queue }
      let queue = DispatchQueue(label: "codevisor.screen-sharing.v2.decode.\(stream)", qos: .userInteractive)
      queues[stream] = queue
      return queue
    }
    queue.async(execute: work)
  }

  func reset(stream: UInt8) {
    lock.withLock { decoders[stream] }?.discardSession()
  }

  func stop() {
    let all = lock.withLock {
      stopped = true
      return Array(decoders.values)
    }
    for decoder in all { decoder.stop() }
  }

  private func decoder(for stream: UInt8) throws -> ScreenSharingV2Decoder {
    try lock.withLock {
      guard !stopped else { throw ScreenSharingError.unavailable("Decoder stopped.") }

      if let decoder = decoders[stream] { return decoder }
      let decoder = ScreenSharingV2Decoder(metrics: metrics)
      decoders[stream] = decoder
      return decoder
    }
  }
}
