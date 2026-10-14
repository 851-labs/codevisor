import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit
import ScreenSharing

protocol ComputerUseFrameSink: AnyObject, Sendable {
  @MainActor func prepare(size: CGSize)
  func push(_ frame: ScreenSharingVideoFrame)
  var requestedDimension: CGFloat { get }
}

extension ComputerUseFrameSink {
  var requestedDimension: CGFloat { 0 }
}

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

final class ComputerUseFramePublisher: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var sinks: [UUID: any ComputerUseFrameSink] = [:]
  private var callbackCount = 0

  var callbacks: Int { lock.withLock { callbackCount } }

  func setSinks(_ sinks: [UUID: any ComputerUseFrameSink]) {
    lock.withLock { self.sinks = sinks }
  }

  func removeAll() {
    lock.withLock { sinks.removeAll() }
  }

  var currentSinks: [any ComputerUseFrameSink] {
    lock.withLock { Array(sinks.values) }
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
    guard type == .screen else { return }
    lock.withLock { callbackCount += 1 }
    publish(sampleBuffer)
  }
}

final class ComputerUseMailboxSink: ComputerUseFrameSink, @unchecked Sendable {
  let mailbox: ScreenSharingFrameMailbox
  private let lock = NSLock()
  private var displayDimension: CGFloat = 0
  private var cornerRadius = ComputerUseCornerRadiusTracker()
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

  private func measureWindowContent(_ frame: ScreenSharingVideoFrame) -> ComputerUseWindowContent? {
    let buffer = frame.pixelBuffer
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    guard lock.withLock({ cornerRadius.shouldMeasure(size: size) }) else { return nil }
    let measured = computerUseWindowContent(pixelBuffer: buffer)
    return lock.withLock { cornerRadius.record(measured) }
  }
}
