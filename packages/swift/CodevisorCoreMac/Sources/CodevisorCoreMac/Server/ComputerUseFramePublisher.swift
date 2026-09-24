import CoreMedia
import CoreVideo
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
  /// The longer side, in pixels, this sink displays frames at; 0 for no
  /// preference. The stream captures at least that sharp, within a ceiling.
  var requestedDimension: CGFloat { get }
}

extension ComputerUseFrameSink {
  var requestedDimension: CGFloat { 0 }
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
final class ComputerUseMailboxSink: ComputerUseFrameSink, @unchecked Sendable {
  let mailbox: ScreenSharingFrameMailbox
  private let lock = NSLock()
  private var displayDimension: CGFloat = 0
  private var cornerRadius = ComputerUseCornerRadiusTracker()
  /// Called from the capture queue when the window's measured placement
  /// in the frame changes.
  private let onWindowContent: (@Sendable (ComputerUseWindowContent) -> Void)?

  var requestedDimension: CGFloat {
    get { lock.withLock { displayDimension } }
    set { lock.withLock { displayDimension = newValue } }
  }

  init(
    mailbox: ScreenSharingFrameMailbox,
    onWindowContent: (@Sendable (ComputerUseWindowContent) -> Void)? = nil
  ) {
    self.mailbox = mailbox
    self.onWindowContent = onWindowContent
  }

  @MainActor func prepare(size: CGSize) {}

  func push(_ frame: ScreenSharingVideoFrame) {
    if let onWindowContent, let changed = measureWindowContent(frame) {
      onWindowContent(changed)
    }
    mailbox.put(frame)
  }

  /// Re-measures on size changes and periodically; cheap either way (a few
  /// dozen pixels read along six short lines).
  private func measureWindowContent(_ frame: ScreenSharingVideoFrame) -> ComputerUseWindowContent? {
    let buffer = frame.pixelBuffer
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    guard lock.withLock({ cornerRadius.shouldMeasure(size: size) }) else { return nil }
    let measured = computerUseWindowContent(pixelBuffer: buffer)
    return lock.withLock { cornerRadius.record(measured) }
  }
}
