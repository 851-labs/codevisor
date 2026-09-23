import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import ScreenSharing

/// A consumer of one controlled window's live frames: the in-app preview
/// (a mailbox feeding Metal) or a remote viewer (a WebRTC frame sender).
protocol ComputerUseFrameSink: AnyObject, Sendable {
  /// Called before the stream is reconfigured to deliver frames of `size`,
  /// and once on attach with the current size. Frames of the previous size
  /// may still arrive briefly afterwards.
  @MainActor func prepare(size: CGSize)
  /// Called on the capture output queue.
  func push(_ frame: ScreenSharingVideoFrame)
}

/// The frame to deliver for a ScreenCaptureKit sample, or nil for the
/// idle/blank/suspended callbacks SCK sends when nothing changed.
func computerUseLiveFrame(
  from sampleBuffer: CMSampleBuffer,
  receivedAt: Double
) -> ScreenSharingVideoFrame? {
  guard sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return nil }
  guard
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]],
    let status = attachments.first?[.status] as? Int,
    status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue
  else { return nil }
  let time = CMTimeConvertScale(
    sampleBuffer.presentationTimeStamp,
    timescale: 1_000_000_000,
    method: .default
  )
  guard time.isNumeric, time.value >= 0 else { return nil }
  return ScreenSharingVideoFrame(
    pixelBuffer: pixelBuffer,
    timestampNs: time.value,
    receivedAtSeconds: receivedAt
  )
}

/// One per native sharing stream. Fans complete frames out to the sinks of
/// every session sharing the window, without an actor hop.
final class ComputerUseFramePublisher: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var sinks: [UUID: any ComputerUseFrameSink] = [:]

  func setSinks(_ sinks: [UUID: any ComputerUseFrameSink]) {
    lock.withLock { self.sinks = sinks }
  }

  func removeAll() {
    lock.withLock { sinks.removeAll() }
  }

  var currentSinks: [any ComputerUseFrameSink] {
    lock.withLock { Array(sinks.values) }
  }

  var hasSinks: Bool {
    lock.withLock { !sinks.isEmpty }
  }

  func publish(_ sampleBuffer: CMSampleBuffer) {
    let targets = lock.withLock { Array(sinks.values) }
    guard !targets.isEmpty,
      let frame = computerUseLiveFrame(from: sampleBuffer, receivedAt: CACurrentMediaTime())
    else { return }
    for sink in targets { sink.push(frame) }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    // Receiving frames also keeps the system's live sharing preview
    // populated; with no sink attached they are simply released.
    guard type == .screen else { return }
    publish(sampleBuffer)
  }
}

/// Feeds the in-app preview. The mailbox holds only the newest frame.
final class ComputerUseMailboxSink: ComputerUseFrameSink {
  let mailbox: ScreenSharingFrameMailbox

  init(mailbox: ScreenSharingFrameMailbox) {
    self.mailbox = mailbox
  }

  @MainActor func prepare(size: CGSize) {}

  func push(_ frame: ScreenSharingVideoFrame) {
    mailbox.put(frame)
  }
}
