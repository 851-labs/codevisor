import CoreMedia
import Foundation
import VideoToolbox

public final class ScreenSharingDecoder: @unchecked Sendable {
  private final class Context {
    let frame: ScreenSharingEncodedFrame
    let receivedNs: Int64
    let submittedNs = ScreenSharingMetrics.nowNs
    let output: @Sendable (ScreenSharingVideoFrame) -> Void
    let metrics: ScreenSharingMetrics
    let pixelFormat: OSType
    let refreshSignal: ScreenSharingRefreshSignal?
    let refreshGeneration: UInt64?
    let sourceTimestampNs: Int64?
    let hostTiming: ScreenSharingHostFrameTiming?

    init(
      _ frame: ScreenSharingEncodedFrame, receivedNs: Int64, metrics: ScreenSharingMetrics, pixelFormat: OSType,
      refreshSignal: ScreenSharingRefreshSignal?, sourceTimestampNs: Int64?, hostTiming: ScreenSharingHostFrameTiming?,
      output: @escaping @Sendable (ScreenSharingVideoFrame) -> Void
    ) {
      self.frame = frame
      self.receivedNs = receivedNs
      self.metrics = metrics
      self.pixelFormat = pixelFormat
      self.output = output
      self.refreshSignal = refreshSignal
      self.refreshGeneration = frame.isKeyFrame ? refreshSignal?.keyframeGeneration : nil
      self.sourceTimestampNs = sourceTimestampNs
      self.hostTiming = hostTiming
    }

    func deliver(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?) {
      guard status == noErr, !flags.contains(.frameDropped), let image else {
        refreshSignal?.request(resetDecoder: true)
        metrics.increment("decodeErrors")
        return
      }
      guard CVPixelBufferGetPixelFormatType(image) == pixelFormat else {
        metrics.increment("decodeErrors")
        metrics.label("decoderError", "Hardware decoder returned an unexpected pixel format.")
        refreshSignal?.request(resetDecoder: true)
        return
      }
      let decodedNs = ScreenSharingMetrics.nowNs
      metrics.increment("decodedFrames")
      metrics.observe("decode", milliseconds: Double(decodedNs - submittedNs) / 1_000_000)
      metrics.label("decodedPixelFormat", String(CVPixelBufferGetPixelFormatType(image)))
      recordTimeline(decodedNs: decodedNs)
      output(
        ScreenSharingVideoFrame(
          pixelBuffer: image, timestampNs: frame.timestampNs, rtpTimestamp: frame.rtpTimestamp,
          sourceTimestampNs: sourceTimestampNs))
      if frame.isKeyFrame { decodedKeyFrame() }
    }

    private func recordTimeline(decodedNs: Int64) {
      guard let sourceTimestampNs else { return }

      metrics.timeline.decoded(
        ScreenSharingDecodedFrameTiming(
          sourceTimestampNs: sourceTimestampNs, host: hostTiming, decodeInputNs: receivedNs,
          decodeSubmitNs: submittedNs, decodedNs: decodedNs, isKeyFrame: frame.isKeyFrame))
    }

    private func decodedKeyFrame() {
      let now = ScreenSharingMetrics.nowNs
      if metrics.increment("decodedKeyFrames") == 1 {
        metrics.label("firstDecodedKeyframeAtNs", String(now))
      }
      metrics.label("latestDecodedKeyframeAtNs", String(now))
      if let refreshGeneration {
        refreshSignal?.decodedKeyframe(generation: refreshGeneration)
      }
    }
  }

  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var parameterSets: [Data] = []
  private var codec: ScreenSharingVideoCodec
  private var dynamicRange = ScreenSharingDynamicRange.standard
  private let output: @Sendable (ScreenSharingVideoFrame) -> Void
  private var refreshSignal: ScreenSharingRefreshSignal?
  public let metrics: ScreenSharingMetrics

  public init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec = .h264,
    output: @escaping @Sendable (ScreenSharingVideoFrame) -> Void
  ) {
    self.metrics = metrics
    self.codec = codec
    self.output = output
  }

  deinit { stop() }

  package func useRefreshSignal(_ signal: ScreenSharingRefreshSignal) { refreshSignal = signal }

  public func decode(_ frame: ScreenSharingEncodedFrame) throws {
    let receivedNs = ScreenSharingMetrics.nowNs
    if refreshSignal?.consumeDecoderReset() == true { stop() }
    let received = try NALUnitBitstream.nalUnits(frame.data)
    if codec != .h264 {
      guard
        received.allSatisfy({ $0.count >= 2 && $0[$0.startIndex] & 0x80 == 0 && $0[$0.startIndex + 1] & 7 != 0 })
      else {
        throw ScreenSharingError.invalid("Malformed HEVC NAL header.")
      }
    }
    let sourceTimestampNs = ScreenSharingSourceMarker.timestampNs(in: received, codec: codec)
    let hostTiming = ScreenSharingHostTimingMarker.timing(in: received, codec: codec)
    let units = received.filter { !ScreenSharingSourceMarker.isMarker($0, codec: codec) }
    func type(_ unit: Data) -> Int {
      Int(codec == .h264 ? unit[unit.startIndex] & 0x1f : (unit[unit.startIndex] >> 1) & 0x3f)
    }
    let types = codec == .h264 ? [7, 8] : [32, 33, 34]
    let parameters = types.compactMap { wanted in units.first { type($0) == wanted } }
    if parameters.count == types.count, parameterSets != parameters {
      try configure(parameters: parameters)
    }
    guard let session, let format else {
      throw ScreenSharingError.invalid("Waiting for a \(codec.payloadName) keyframe.")
    }
    let slices = units.filter { (codec == .h264 ? 1...5 : 0...31).contains(type($0)) }
    guard !slices.isEmpty else { return }
    let sample = try sample(
      NALUnitBitstream.lengthPrefixed(units), format: format, timestampNs: frame.timestampNs)
    let context = Unmanaged.passRetained(
      Context(
        frame, receivedNs: receivedNs, metrics: metrics, pixelFormat: codec.decodedPixelFormat(dynamicRange),
        refreshSignal: refreshSignal, sourceTimestampNs: sourceTimestampNs, hostTiming: hostTiming, output: output))
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], frameRefcon: context.toOpaque(), infoFlagsOut: nil)
    if status != noErr {
      context.release()
      metrics.increment("decodeErrors")
      try check(status, "Decode frame")
    }
  }

  private func sample(
    _ bytes: Data, format: CMVideoFormatDescription, timestampNs: Int64
  ) throws -> CMSampleBuffer {
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
      duration: .invalid, presentationTimeStamp: CMTime(value: timestampNs, timescale: 1_000_000_000),
      decodeTimeStamp: .invalid)
    var size = bytes.count
    try check(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample), "Create decode sample")
    guard let sample else { throw ScreenSharingError.unavailable("No decode sample.") }
    return sample
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

  private func configure(parameters: [Data]) throws {
    var description: CMFormatDescription?
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
      guard let streamCodec = actual.codec, let range = actual.dynamicRange else {
        try actual.validate(for: codec); return
      }
      codec = streamCodec
      dynamicRange = range
      metrics.label("decodedChroma", actual.chroma == 3 ? "4:4:4" : "4:2:0")
      metrics.label("decodedBitDepth", String(actual.lumaDepth))
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    guard (1...3840).contains(dimensions.width), (1...2160).contains(dimensions.height) else {
      throw ScreenSharingError.invalid("Unsupported decoded dimensions.")
    }
    stop()
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { _, sourceContext, status, flags, image, _, _ in
        guard let sourceContext else { return }
        Unmanaged<Context>.fromOpaque(sourceContext).takeRetainedValue()
          .deliver(status: status, flags: flags, image: image)
      }, decompressionOutputRefCon: nil)
    let specification =
      [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: Self.requiresHardware]
      as CFDictionary
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: codec.decodedPixelFormat(dynamicRange),
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
      if hardwareStatus == noErr, Self.requiresHardware {
        guard hardwareValue as? Bool == true else {
          throw ScreenSharingError.unavailable("\(codec.payloadName) decoder is not hardware backed.")
        }
      } else if hardwareStatus != kVTPropertyNotSupportedErr {
        try check(hardwareStatus, "Query decoder hardware")
      }
      metrics.label("decoderHardware", Self.hardwareLabel(status: hardwareStatus))
      format = description
      parameterSets = parameters
      metrics.label("decoder", "VideoToolbox \(codec.rawValue) \(Self.requiresHardware ? "hardware" : "software")")
    } catch { stop(); throw error }
  }

  private static var requiresHardware: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      true
    #endif
  }

  private static func hardwareLabel(status: OSStatus) -> String {
    guard requiresHardware else { return "simulator (software)" }
    return status == noErr ? "confirmed" : "required; query unsupported"
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ScreenSharingError.codec(operation, status) }
  }
}
