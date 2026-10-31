import CoreMedia
import Foundation
import ScreenSharing
import VideoToolbox

final class ScreenSharingV2Decoder: @unchecked Sendable {
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var parameterSets: [Data] = []
  private let metrics: ScreenSharingMetrics
  private let lock = NSLock()
  private var stopped = false

  init(metrics: ScreenSharingMetrics) {
    self.metrics = metrics
  }

  deinit { closeSession() }

  func decode(
    _ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64,
    output: @escaping @Sendable (ScreenSharingV2DecodeResult) -> Void
  ) throws {
    try lock.withLock {
      guard !stopped else { throw ScreenSharingError.unavailable("Decoder stopped.") }

      try decodeLocked(frame, meta: meta, receivedNs: receivedNs, output: output)
    }
  }

  func stop() {
    lock.withLock {
      stopped = true
      closeSession()
    }
  }

  private func decodeLocked(
    _ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64,
    output: @escaping @Sendable (ScreenSharingV2DecodeResult) -> Void
  ) throws {
    let sample = try frame.payload.withUnsafeBytes { bytes in
      let layout = try ScreenSharingV2AccessUnitLayout(bytes)
      try configure(layout.parameterSets)
      return try self.sample(UnsafeRawBufferPointer(rebasing: bytes[layout.sliceOffset...]))
    }
    let context = ScreenSharingV2DecodeContext(
      frame: frame, meta: meta, receivedNs: receivedNs, submittedNs: ScreenSharingMetrics.nowNs, output: output)
    try submit(sample, context: context)
  }

  private func closeSession() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    format = nil
    parameterSets = []
  }

  private func submit(_ sample: CMSampleBuffer, context: ScreenSharingV2DecodeContext) throws {
    guard let session else { throw ScreenSharingError.invalid("Waiting for an HEVC keyframe.") }

    let retained = Unmanaged.passRetained(context)
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], frameRefcon: retained.toOpaque(), infoFlagsOut: nil)
    guard status != noErr else { return }

    retained.release()
    guard status != kVTInvalidSessionErr else {
      closeSession()
      throw ScreenSharingV2DecoderError.sessionLost
    }
    throw ScreenSharingError.codec("Decode frame", status)
  }

  private func configure(_ received: [Data]) throws {
    guard !received.isEmpty, received != parameterSets else { return }

    let description = try ScreenSharingV2FormatDescription.make(parameterSets: received)
    closeSession()
    session = try ScreenSharingV2DecompressionSessionFactory.make(format: description)
    format = description
    parameterSets = received
    metrics.label("decoder", "VideoToolbox HEVC hardware")
  }

  private func sample(_ bytes: UnsafeRawBufferPointer) throws -> CMSampleBuffer {
    guard let format else { throw ScreenSharingError.invalid("Waiting for an HEVC keyframe.") }

    let block = try Self.block(copying: bytes)
    var sample: CMSampleBuffer?
    var size = bytes.count
    try Self.check(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sample), "Create decode sample")
    guard let sample else { throw ScreenSharingError.unavailable("No decode sample.") }

    return sample
  }

  private static func block(copying bytes: UnsafeRawBufferPointer) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    try check(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
        flags: 0, blockBufferOut: &block), "Allocate decode buffer")
    guard let block, let base = bytes.baseAddress else { throw ScreenSharingError.unavailable("No decode buffer.") }

    try check(
      CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count),
      "Copy decode buffer")
    return block
  }

  private static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ScreenSharingError.codec(operation, status) }
  }
}
