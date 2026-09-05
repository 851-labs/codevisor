import AVFoundation
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit sends frames only when content changes. Keep their timestamps
/// and explicitly repeat the final frame so a still result remains visible until stop.
final class ComputerUseVideoWriter: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue = DispatchQueue(label: "com.codevisor.computer-use.video-writer")
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let frameDuration: CMTime
  private var origin: CMTime?
  private var lastTime = CMTime.zero
  private var lastFrame: CVPixelBuffer?
  private var finishing = false
  private let onStarted: @Sendable () -> Void
  private let onFinished: @Sendable (Double) -> Void
  private let onError: @Sendable (Error) -> Void

  init(
    url: URL, size: CGSize, fps: Int, onStarted: @escaping @Sendable () -> Void,
    onFinished: @escaping @Sendable (Double) -> Void, onError: @escaping @Sendable (Error) -> Void
  ) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: min(16_000_000, Int(size.width * size.height) * 5),
          AVVideoExpectedSourceFrameRateKey: fps,
        ],
      ])
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    frameDuration = CMTime(value: 1, timescale: Int32(fps))
    self.onStarted = onStarted
    self.onFinished = onFinished
    self.onError = onError
    super.init()
    guard writer.canAdd(input) else { throw BridgeError("The video encoder does not support these dimensions.") }
    writer.add(input)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int,
      status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue,
      let frame = sampleBuffer.imageBuffer
    else { return }
    append(frame, at: sampleBuffer.presentationTimeStamp)
  }

  /// Called only on the output queue, including by the synthetic video regression.
  func append(_ frame: CVPixelBuffer, at time: CMTime) {
    guard !finishing, time.isNumeric else { return }
    if origin == nil {
      guard writer.startWriting() else { failWriter(); return }
      writer.startSession(atSourceTime: .zero)
      origin = time
    }
    let timestamp = CMTimeSubtract(time, origin!)
    guard timestamp >= .zero, lastFrame == nil || timestamp > lastTime,
      input.isReadyForMoreMediaData
    else { return }
    guard adaptor.append(frame, withPresentationTime: timestamp) else { failWriter(); return }
    let first = lastFrame == nil
    lastFrame = frame
    lastTime = timestamp
    if first { onStarted() }
  }

  func finish(duration: Double) {
    queue.async { [self] in
      guard !finishing else { return }
      finishing = true
      guard let lastFrame else {
        writer.cancelWriting(); onError(BridgeError("No video frames were captured.")); return
      }
      let requestedEnd = CMTime(seconds: duration, preferredTimescale: 60000)
      let finalFrameTime = max(lastTime + frameDuration, requestedEnd - frameDuration)
      let endTime = finalFrameTime + frameDuration
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while !input.isReadyForMoreMediaData && writer.status == .writing
        && ProcessInfo.processInfo.systemUptime < deadline
      {
        Thread.sleep(forTimeInterval: 0.005)
      }
      guard input.isReadyForMoreMediaData, adaptor.append(lastFrame, withPresentationTime: finalFrameTime) else {
        failWriter(); return
      }
      self.lastFrame = nil
      writer.endSession(atSourceTime: endTime)
      input.markAsFinished()
      writer.finishWriting { [self] in
        if writer.status == .completed {
          onFinished(CMTimeGetSeconds(endTime))
        } else {
          onError(writer.error ?? BridgeError("The video file could not be finalized."))
        }
      }
    }
  }

  func cancel() {
    queue.async { [self] in
      finishing = true
      lastFrame = nil
      if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    }
  }

  private func failWriter() {
    finishing = true
    lastFrame = nil
    onError(writer.error ?? BridgeError("The video encoder could not accept a frame."))
  }
}
