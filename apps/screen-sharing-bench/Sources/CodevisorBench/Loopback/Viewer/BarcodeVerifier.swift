import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingBench

final class BarcodeVerifier: @unchecked Sendable {
  private let mailbox: ScreenSharingFrameMailbox
  private let canvasWidth: Int
  private let tap: ScreenSharingFrameMailbox
  private let id = UUID()
  private let queue = DispatchQueue(label: "codevisor.bench.barcode", qos: .utility)
  private let lock = NSLock()
  private var versions: [Int64: Int?] = [:]

  init(mailbox: ScreenSharingFrameMailbox, canvasWidth: Int) {
    self.mailbox = mailbox
    self.canvasWidth = canvasWidth
    tap = mailbox.tap(id)
    tap.onFrameAvailable { [weak self] in self?.scheduleDrain() }
  }

  func stop() -> [Int64: Int?] {
    mailbox.untap(id)
    tap.onFrameAvailable(nil)
    return queue.sync { lock.withLock { versions } }
  }

  private func scheduleDrain() {
    queue.async { [weak self] in self?.drain() }
  }

  private func drain() {
    while let frame = tap.take() {
      guard let sourceNs = frame.sourceTimestampNs else { continue }

      let version = LoopbackBarcode.version(in: frame.pixelBuffer, canvasWidth: canvasWidth)
      lock.withLock { versions[sourceNs] = version }
    }
  }
}
