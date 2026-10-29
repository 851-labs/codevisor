import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingBench

final class BarcodeVerifier: @unchecked Sendable {
  struct Decoded {
    let versions: [Int64: Int?]
    let rtpTimestamps: [Int64: UInt32]
  }

  private let mailbox: ScreenSharingFrameMailbox
  private let canvasWidth: Int
  private let tap: ScreenSharingFrameMailbox
  private let id = UUID()
  private let queue = DispatchQueue(label: "codevisor.bench.barcode", qos: .utility)
  private let lock = NSLock()
  private var versions: [Int64: Int?] = [:]
  private var rtpTimestamps: [Int64: UInt32] = [:]

  init(mailbox: ScreenSharingFrameMailbox, canvasWidth: Int) {
    self.mailbox = mailbox
    self.canvasWidth = canvasWidth
    tap = mailbox.tap(id)
    tap.onFrameAvailable { [weak self] in self?.scheduleDrain() }
  }

  func stop() -> Decoded {
    mailbox.untap(id)
    tap.onFrameAvailable(nil)
    return queue.sync { lock.withLock { Decoded(versions: versions, rtpTimestamps: rtpTimestamps) } }
  }

  private func scheduleDrain() {
    queue.async { [weak self] in self?.drain() }
  }

  private func drain() {
    while let frame = tap.take() {
      guard let sourceNs = frame.sourceTimestampNs else { continue }

      let version = LoopbackBarcode.version(in: frame.pixelBuffer, canvasWidth: canvasWidth)
      lock.withLock {
        versions[sourceNs] = version
        if rtpTimestamps[sourceNs] == nil { rtpTimestamps[sourceNs] = frame.rtpTimestamp }
      }
    }
  }
}
