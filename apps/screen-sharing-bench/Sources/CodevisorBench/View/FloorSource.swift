import CoreVideo
import Foundation
import QuartzCore
import ScreenSharing
import ScreenSharingBench
import Synchronization

final class FloorSource: @unchecked Sendable {
  private static let bufferCount = 8
  private static let receiveTimeout = Duration.milliseconds(100)

  let port: UInt16
  private let receiver: BenchVersionReceiver
  private let mailbox: ScreenSharingFrameMailbox
  private let buffers: [CVPixelBuffer]
  private let isStopped = Atomic(false)
  private let presented = Atomic(0)
  private let latest = Atomic(0)
  private let failure = Mutex<String?>(nil)

  init(port: UInt16, mailbox: ScreenSharingFrameMailbox, pixelSize: CGSize) throws {
    receiver = try BenchVersionReceiver(port: port, receiveTimeout: Self.receiveTimeout)
    self.port = receiver.port
    self.mailbox = mailbox
    buffers = try BarcodePixelBuffers.make(
      count: Self.bufferCount, width: Int(pixelSize.width), height: Int(pixelSize.height))
  }

  var presentedVersions: Int { presented.load(ordering: .relaxed) }
  var latestVersion: Int { latest.load(ordering: .relaxed) }
  var lastError: String? { failure.withLock { $0 } }

  func start() {
    let thread = Thread { [self] in serve() }
    thread.name = "Floor version receiver"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() {
    isStopped.store(true, ordering: .relaxed)
  }

  private func serve() {
    while !isStopped.load(ordering: .relaxed) {
      do {
        guard let message = try receiver.receive(), message.version > latestVersion else { continue }

        try present(message.version)
      } catch {
        failure.withLock { $0 = "\(error)" }
      }
    }
  }

  private func present(_ version: Int) throws {
    let buffer = buffers[version % buffers.count]
    try BenchBarcode.draw(version, into: buffer, layout: .standard)
    let nowNs = ScreenSharingMetrics.nowNs
    mailbox.put(
      ScreenSharingVideoFrame(
        pixelBuffer: buffer, timestampNs: nowNs, receivedAtSeconds: CACurrentMediaTime(), sourceTimestampNs: nowNs))
    latest.store(version, ordering: .relaxed)
    presented.add(1, ordering: .relaxed)
  }
}
