import CoreMedia
import Foundation
import VideoToolbox

/// Decode and stop are serialized by the transport's decoder queue. The VT
/// callback retains only immutable frame metadata and a thread-safe sink.
public final class ScreenSharingDecoder: @unchecked Sendable {
  private final class Context {
    let frame: ScreenSharingEncodedFrame
    let startedNs = ScreenSharingMetrics.nowNs
    let output: @Sendable (ScreenSharingVideoFrame) -> Void
    let metrics: ScreenSharingMetrics
    let pixelFormat: OSType
    let refreshSignal: ScreenSharingRefreshSignal?
    let refreshGeneration: UInt64?
    let sourceTimestampNs: Int64?
    let audit: ScreenSharingFrameDeliveryAudit?
    let auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?

    init(
      _ frame: ScreenSharingEncodedFrame, metrics: ScreenSharingMetrics, pixelFormat: OSType,
      refreshSignal: ScreenSharingRefreshSignal?, sourceTimestampNs: Int64?,
      audit: ScreenSharingFrameDeliveryAudit?, auditIdentity: ScreenSharingFrameDeliveryAudit.Identity?,
      output: @escaping @Sendable (ScreenSharingVideoFrame) -> Void
    ) {
      self.frame = frame
      self.metrics = metrics
      self.pixelFormat = pixelFormat
      self.output = output
      self.refreshSignal = refreshSignal
      self.refreshGeneration = frame.isKeyFrame ? refreshSignal?.keyframeGeneration : nil
      self.sourceTimestampNs = sourceTimestampNs
      self.audit = audit
      self.auditIdentity = auditIdentity
    }
  }

  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var parameterSets: [Data] = []
  private let codec: ScreenSharingVideoCodec
  private let output: @Sendable (ScreenSharingVideoFrame) -> Void
  private var refreshSignal: ScreenSharingRefreshSignal?
  public let metrics: ScreenSharingMetrics
  /// Receiver-only diagnostic audit; nil = no identity, no attachment, no recording.
  private let audit: ScreenSharingFrameDeliveryAudit?

  public init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec = .h264,
    deliveryAudit: ScreenSharingFrameDeliveryAudit? = nil,
    output: @escaping @Sendable (ScreenSharingVideoFrame) -> Void
  ) {
    self.metrics = metrics
    self.codec = codec
    self.audit = deliveryAudit
    self.output = output
  }

  deinit { stop() }

  /// Installed on the serialized decoder queue before accepting frames.
  package func useRefreshSignal(_ signal: ScreenSharingRefreshSignal) { refreshSignal = signal }

  public func decode(
    _ frame: ScreenSharingEncodedFrame, auditIdentity: ScreenSharingFrameDeliveryAudit.Identity? = nil
  ) throws {
    // VT callbacks only mark the reset. Session teardown belongs on this
    // queue, since waiting for callbacks from inside a callback can deadlock.
    if refreshSignal?.consumeDecoderReset() == true { stop() }
    let received = try NALUnitBitstream.nalUnits(frame.data)
    if codec != .h264 {
      guard
        received.allSatisfy({ $0.count >= 2 && $0[$0.startIndex] & 0x80 == 0 && $0[$0.startIndex + 1] & 7 != 0 })
      else {
        throw ScreenSharingError.invalid("Malformed HEVC NAL header.")
      }
    }
    // The host's content marker is read here and never reaches VideoToolbox.
    let sourceTimestampNs = ScreenSharingSourceMarker.timestampNs(in: received, codec: codec)
    let units = received.filter { !ScreenSharingSourceMarker.isMarker($0, codec: codec) }
    func type(_ unit: Data) -> Int {
      Int(codec == .h264 ? unit[unit.startIndex] & 0x1f : (unit[unit.startIndex] >> 1) & 0x3f)
    }
    let types = codec == .h264 ? [7, 8] : [32, 33, 34]
    let parameters = types.compactMap { wanted in units.first { type($0) == wanted } }
    if parameters.count == types.count, parameterSets != parameters {
      try configure(parameters: parameters, auditIdentity: auditIdentity, rtpTimestamp: frame.rtpTimestamp)
    }
    guard let session, let format else {
      throw ScreenSharingError.invalid("Waiting for a \(codec.payloadName) keyframe.")
    }
    let slices = units.filter { (codec == .h264 ? 1...5 : 0...31).contains(type($0)) }
    guard !slices.isEmpty else { return }
    let bytes = try NALUnitBitstream.lengthPrefixed(units)
    var block: CMBlockBuffer?
    try check(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: bytes.count, flags: 0, blockBufferOut: &block), "Allocate decode buffer")
    guard let block else { throw ScreenSharingError.unavailable("No decode buffer.") }
    try bytes.withUnsafeBytes { raw in
      try check(
        CMBlockBufferReplaceDataBytes(
          with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count),
        "Copy decode buffer")
    }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: frame.timestampNs, timescale: 1_000_000_000),
      decodeTimeStamp: .invalid)
    var size = bytes.count
    try check(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample), "Create decode sample")
    guard let sample else { throw ScreenSharingError.unavailable("No decode sample.") }
    let context = Unmanaged.passRetained(
      Context(
        frame, metrics: metrics, pixelFormat: codec.decodedPixelFormat, refreshSignal: refreshSignal,
        sourceTimestampNs: sourceTimestampNs, audit: audit, auditIdentity: auditIdentity, output: output))
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], frameRefcon: context.toOpaque(), infoFlagsOut: nil)
    if status != noErr {
      context.release()
      metrics.increment("decodeErrors")
      try check(status, "Decode frame")
    }
  }

  public func stop() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    format = nil
    parameterSets = []
  }

  private func configure(
    parameters: [Data], auditIdentity: ScreenSharingFrameDeliveryAudit.Identity? = nil, rtpTimestamp: UInt32 = 0
  ) throws {
    var description: CMFormatDescription?
    // NSData keeps every parameter's storage stable across the C API call.
    let retained = parameters.map { $0 as NSData }
    let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = retained.map(\.length)
    let status: OSStatus = withExtendedLifetime(retained) {
      if codec == .h264 {
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: parameters.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &description)
      }
      return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault,
        parameterSetCount: parameters.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
    }
    try check(status, "Read \(codec.payloadName) format")
    guard let description else { throw ScreenSharingError.invalid("Missing \(codec.payloadName) format.") }
    if codec != .h264 {
      let actual = try ScreenSharingHEVCFormat.read(description)
      try actual.validate(for: codec)
      metrics.label("decodedChroma", actual.chroma == 3 ? "4:4:4" : "4:2:0")
      metrics.label("decodedBitDepth", String(actual.lumaDepth))
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    guard (1...3840).contains(dimensions.width), (1...2160).contains(dimensions.height) else {
      throw ScreenSharingError.invalid("Unsupported decoded dimensions.")
    }
    stop()
    // A new VideoToolbox session: recorded against the triggering input's
    // identity; that input keeps its epoch, later inputs carry the new one.
    audit?.decoderConfigured(auditIdentity, rtpTimestamp: rtpTimestamp)
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { _, sourceContext, status, flags, image, _, _ in
        guard let sourceContext else { return }
        let context = Unmanaged<Context>.fromOpaque(sourceContext).takeRetainedValue()
        guard status == noErr, !flags.contains(.frameDropped), let image else {
          context.refreshSignal?.request(resetDecoder: true)
          context.metrics.increment("decodeErrors"); return
        }
        guard CVPixelBufferGetPixelFormatType(image) == context.pixelFormat else {
          context.metrics.increment("decodeErrors")
          context.metrics.label("decoderError", "Hardware decoder returned an unexpected pixel format.")
          context.refreshSignal?.request(resetDecoder: true)
          return
        }
        context.metrics.increment("decodedFrames")
        context.metrics.observe(
          "decode", milliseconds: Double(ScreenSharingMetrics.nowNs - context.startedNs) / 1_000_000)
        context.metrics.label("decodedPixelFormat", String(CVPixelBufferGetPixelFormatType(image)))
        if let audit = context.audit {
          // Diagnostic-only scalar attachment, stamped on EVERY output while the
          // audit is on: a nil identity clears the previous value, so a reused
          // pool buffer never carries a stale identity to the bridge.
          ScreenSharingFrameDeliveryAudit.stamp(context.auditIdentity, on: image)
          audit.record(.vtOutput, context.auditIdentity, rtpTimestamp: context.frame.rtpTimestamp)
        }
        context.output(
          ScreenSharingVideoFrame(
            pixelBuffer: image, timestampNs: context.frame.timestampNs, rtpTimestamp: context.frame.rtpTimestamp,
            sourceTimestampNs: context.sourceTimestampNs))
        if context.frame.isKeyFrame {
          let now = ScreenSharingMetrics.nowNs
          if context.metrics.increment("decodedKeyFrames") == 1 {
            context.metrics.label("firstDecodedKeyframeAtNs", String(now))
          }
          context.metrics.label("latestDecodedKeyframeAtNs", String(now))
          if let generation = context.refreshGeneration {
            context.refreshSignal?.decodedKeyframe(generation: generation)
          }
        }
      }, decompressionOutputRefCon: nil)
    let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: codec.decodedPixelFormat,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    var created: VTDecompressionSession?
    try check(
      VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: specification,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback,
        decompressionSessionOut: &created), "Create hardware decoder")
    guard let created else { throw ScreenSharingError.unavailable("No hardware \(codec.payloadName) decoder.") }
    session = created
    do {
      try check(
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue),
        "Set real-time decoding")
      var hardware: Unmanaged<CFTypeRef>?
      let hardwareStatus = VTSessionCopyProperty(
        created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: nil, valueOut: &hardware)
      let hardwareValue = hardware?.takeRetainedValue()
      if hardwareStatus == noErr {
        guard hardwareValue as? Bool == true else {
          throw ScreenSharingError.unavailable("\(codec.payloadName) decoder is not hardware backed.")
        }
      } else if hardwareStatus != kVTPropertyNotSupportedErr {
        try check(hardwareStatus, "Query decoder hardware")
      }
      // Some low-latency VT implementations omit this diagnostic property.
      // RequireHardwareAcceleratedVideoDecoder still forbids software fallback.
      metrics.label("decoderHardware", hardwareStatus == noErr ? "confirmed" : "required; query unsupported")
      format = description
      parameterSets = parameters
      metrics.label("decoder", "VideoToolbox \(codec.rawValue) hardware")
    } catch { stop(); throw error }
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ScreenSharingError.codec(operation, status) }
  }
}
