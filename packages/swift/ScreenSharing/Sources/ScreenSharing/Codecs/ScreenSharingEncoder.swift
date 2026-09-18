import CoreMedia
import Foundation
import VideoToolbox

/// WebRTC calls encode/rate/release serially. VT output arrives on its own
/// queue; callback and pending metadata are protected by the lock. Stop drains
/// VT before releasing its bounded callback metadata.
public final class ScreenSharingEncoder: @unchecked Sendable {
  private final class Pending: Sendable {
    let timestampNs: Int64
    let sourceTimestampNs: Int64
    let rtpTimestamp: UInt32
    let keyframeAttempt: ScreenSharingKeyframeRequest.Attempt?
    let startedNs = ScreenSharingMetrics.nowNs
    init(frame: ScreenSharingVideoFrame, keyframeAttempt: ScreenSharingKeyframeRequest.Attempt?) {
      timestampNs = frame.timestampNs
      // Direct codec users (standalone probes) identify content by their own
      // input timestamp; the transport adapter always supplies buffer identity.
      sourceTimestampNs = frame.sourceTimestampNs ?? frame.timestampNs
      rtpTimestamp = frame.rtpTimestamp
      self.keyframeAttempt = keyframeAttempt
    }
  }

  private let lock = NSLock()
  private var pending: [Int64: Pending] = [:]
  private var pendingHighWater = 0
  private var keyframeRequest = ScreenSharingKeyframeRequest()
  private var dropCheck: ScreenSharingEncoderDropCheck?
  private var session: VTCompressionSession?
  private var output: (@Sendable (ScreenSharingEncodedFrame) -> Void)?
  private let configuration: ScreenSharingVideoConfiguration
  private let codec: ScreenSharingVideoCodec
  private let maximumPendingFrames: Int
  private let completeEachFrame: Bool
  private var currentBitrate: Int
  private var currentFPS: Int
  public let metrics: ScreenSharingMetrics

  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    useLowLatencyRateControl: Bool = true, codec: ScreenSharingVideoCodec = .h264,
    disableLookAhead: Bool = false, maximumPendingFrames: Int = 2, completeEachFrame: Bool = false,
    prioritizeSpeed: Bool = false, keyframeIntervalSeconds: Int = 2
  ) throws {
    self.configuration = configuration
    currentBitrate = configuration.bitrate
    currentFPS = configuration.framesPerSecond
    self.metrics = metrics
    self.codec = codec
    guard (1...8).contains(maximumPendingFrames) else {
      throw ScreenSharingError.invalid("Encoder admission must be bounded to 1...8 frames.")
    }
    guard (1...60).contains(keyframeIntervalSeconds) else {
      throw ScreenSharingError.invalid("Keyframe interval must be bounded to 1...60 seconds.")
    }
    self.maximumPendingFrames = maximumPendingFrames
    self.completeEachFrame = completeEachFrame
    metrics.label("encoderCompletion", completeEachFrame ? "synchronous drain experiment" : "callback")
    metrics.label("encoderMaximumPendingFrames", String(maximumPendingFrames))
    metrics.label("encoderInitialBitrate", String(configuration.bitrate))
    metrics.label("encoderInitialFPS", String(configuration.framesPerSecond))
    metrics.label("encoderKeyframeIntervalSeconds", String(keyframeIntervalSeconds))
    guard codec != .hevc444 || !useLowLatencyRateControl else {
      throw ScreenSharingError.invalid(
        "Main444 requires standard rate control; the low-latency encoder can reduce chroma.")
    }
    var created: VTCompressionSession?
    var specification: [CFString: Any] = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
    ]
    if useLowLatencyRateControl { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    try check(
      VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(configuration.width), height: Int32(configuration.height),
        codecType: codec.mediaType, encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &created), "Create encoder")
    guard let created else { throw ScreenSharingError.unavailable("No hardware \(codec.payloadName) encoder.") }
    session = created
    do {
      try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
      try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
      if prioritizeSpeed {
        try property(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
      }
      metrics.label("encoderSpeedPolicy", prioritizeSpeed ? "prioritize speed" : "encoder default")
      metrics.label("encoderRateControl", useLowLatencyRateControl ? "low latency" : "standard")
      if codec == .hevc444 {
        var supported: CFDictionary?
        try check(
          VTSessionCopySupportedPropertyDictionary(created, supportedPropertyDictionaryOut: &supported),
          "Read encoder properties")
        let profileInfo =
          (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
        let profiles = profileInfo?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
        guard let profile = profiles.first(where: { $0.contains("_Main444_") }) else {
          throw ScreenSharingError.unavailable("Hardware encoder does not advertise an 8-bit Main444 profile.")
        }
        try property(kVTCompressionPropertyKey_ProfileLevel, profile as CFString)
        metrics.label("encoderProfile", profile)
      } else {
        try property(
          kVTCompressionPropertyKey_ProfileLevel,
          codec == .h264 ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
      }
      try property(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond as CFNumber)
      if disableLookAhead {
        guard !useLowLatencyRateControl else {
          throw ScreenSharingError.invalid("Lookahead is controlled by the low-latency encoder.")
        }
        #if os(macOS)
          try property(kVTCompressionPropertyKey_SuggestedLookAheadFrameCount, 0 as CFNumber)
          metrics.label("encoderSuggestedLookAheadFrames", "0")
        #else
          throw ScreenSharingError.unavailable("The lookahead experiment requires macOS.")
        #endif
      }
      try property(kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber)
      try property(
        kVTCompressionPropertyKey_MaxKeyFrameInterval,
        (configuration.framesPerSecond * keyframeIntervalSeconds) as CFNumber)
      try property(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
      try property(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
      try property(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
      try check(VTCompressionSessionPrepareToEncodeFrames(created), "Prepare encoder")
      var hardware: Unmanaged<CFTypeRef>?
      let hardwareStatus = VTSessionCopyProperty(
        created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        allocator: nil, valueOut: &hardware)
      let hardwareValue = hardware?.takeRetainedValue()
      if hardwareStatus == noErr {
        guard hardwareValue as? Bool == true else {
          throw ScreenSharingError.unavailable("\(codec.payloadName) encoder is not hardware backed.")
        }
      } else if hardwareStatus != kVTPropertyNotSupportedErr {
        try check(hardwareStatus, "Query encoder hardware")
      }
      // Some low-latency VT implementations omit this diagnostic property.
      // RequireHardwareAcceleratedVideoEncoder still forbids software fallback.
      metrics.label("encoderHardware", hardwareStatus == noErr ? "confirmed" : "required; query unsupported")
      metrics.label("encoder", "VideoToolbox \(codec.rawValue) hardware, no frame reordering")
      metrics.label("encodedColor", "BT.709 SDR")
    } catch { stop(); throw error }
  }

  deinit { stop() }

  public func onFrame(_ callback: @escaping @Sendable (ScreenSharingEncodedFrame) -> Void) {
    lock.withLock { output = callback }
  }

  package func useDropCheck(_ check: ScreenSharingEncoderDropCheck) {
    lock.withLock { dropCheck = check }
  }

  @discardableResult
  public func encode(_ frame: ScreenSharingVideoFrame, forceKeyFrame: Bool = false) throws -> Bool {
    metrics.increment("encoderInputFrames")
    metrics.event("encoderInputInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    metrics.event("encoderInputTimestampInterval", atNanoseconds: frame.timestampNs)
    guard let session else { throw ScreenSharingError.unavailable("Encoder stopped.") }
    guard frame.timestampNs >= 0,
      CVPixelBufferGetWidth(frame.pixelBuffer) == configuration.width,
      CVPixelBufferGetHeight(frame.pixelBuffer) == configuration.height
    else { throw ScreenSharingError.invalid("Encoder input size or timestamp does not match its configuration.") }
    if forceKeyFrame { metrics.increment("encoderKeyframeRequests") }
    let metadata: Pending? = lock.withLock {
      if forceKeyFrame { keyframeRequest.request() }
      guard pending.count < maximumPendingFrames, pending[frame.timestampNs] == nil else {
        if keyframeRequest.isPending { metrics.increment("encoderDeferredKeyframeRequests") }
        return nil
      }
      let metadata = Pending(frame: frame, keyframeAttempt: keyframeRequest.beginAttempt())
      pending[frame.timestampNs] = metadata
      if pending.count > pendingHighWater {
        pendingHighWater = pending.count
        metrics.label("encoderPendingHighWater", String(pendingHighWater))
      }
      return metadata
    }
    guard let metadata else {
      metrics.increment("encoderBackpressureDrops")
      metrics.trace("encoderAdmission", "\(ScreenSharingMetrics.nowNs) ts=\(frame.timestampNs) dropped=backpressure")
      return false
    }
    if metadata.keyframeAttempt != nil { metrics.increment("encoderForcedKeyframesSubmitted") }
    metrics.trace(
      "encoderAdmission",
      "\(ScreenSharingMetrics.nowNs) ts=\(frame.timestampNs) id=\(metadata.sourceTimestampNs) force=\(forceKeyFrame) attempt=\(metadata.keyframeAttempt != nil)"
    )
    let submitted = ScreenSharingMetrics.nowNs
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: frame.pixelBuffer,
      presentationTimeStamp: CMTime(value: frame.timestampNs, timescale: 1_000_000_000),
      duration: CMTime(value: 1, timescale: Int32(configuration.framesPerSecond)),
      frameProperties: metadata.keyframeAttempt != nil
        ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
      infoFlagsOut: nil
    ) { [weak self, metadata] status, flags, buffer in
      self?.didEncode(metadata: metadata, status: status, flags: flags, buffer: buffer)
    }
    metrics.observe("encodeSubmission", milliseconds: Double(ScreenSharingMetrics.nowNs - submitted) / 1_000_000)
    if status != noErr {
      _ = lock.withLock { pending.removeValue(forKey: frame.timestampNs) }
      finishKeyframeAttempt(metadata, producedKeyFrame: false)
      try check(status, "Encode frame")
    }
    if completeEachFrame {
      let started = ScreenSharingMetrics.nowNs
      try check(
        VTCompressionSessionCompleteFrames(
          session, untilPresentationTimeStamp: CMTime(value: frame.timestampNs, timescale: 1_000_000_000)),
        "Complete encoded frame")
      metrics.observe("encoderDrain", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    }
    return true
  }

  public func setBitrate(_ bitsPerSecond: Int, framesPerSecond: Int) throws {
    guard session != nil else { throw ScreenSharingError.unavailable("Encoder stopped.") }
    guard bitsPerSecond > 0, (1...60).contains(framesPerSecond) else {
      throw ScreenSharingError.invalid("Invalid encoder rate.")
    }
    let started = ScreenSharingMetrics.nowNs
    metrics.increment("encoderRateUpdateRequests")
    if currentBitrate != bitsPerSecond {
      try property(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
      currentBitrate = bitsPerSecond
      metrics.increment("encoderBitratePropertyUpdates")
    }
    if currentFPS != framesPerSecond {
      try property(kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
      currentFPS = framesPerSecond
      metrics.increment("encoderFPSPropertyUpdates")
    }
    metrics.observe("encoderRateUpdate", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    metrics.label("encoderRequestedBitrate", String(bitsPerSecond))
    metrics.label("encoderRequestedFPS", String(framesPerSecond))
  }

  public func stop() {
    guard let active = session else { return }
    session = nil
    VTCompressionSessionCompleteFrames(active, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(active)
    lock.withLock {
      metrics.label("encoderPendingAtStop", String(pending.count))
      pending.removeAll(); output = nil
      keyframeRequest = ScreenSharingKeyframeRequest()
    }
  }

  /// Frames admitted and not yet completed by VideoToolbox (diagnostic).
  public var pendingCount: Int { lock.withLock { pending.count } }

  private func didEncode(metadata: Pending, status: OSStatus, flags: VTEncodeInfoFlags, buffer: CMSampleBuffer?) {
    var producedKeyFrame = false
    defer { finishKeyframeAttempt(metadata, producedKeyFrame: producedKeyFrame) }
    let callbackStarted = ScreenSharingMetrics.nowNs
    metrics.observe("videoToolboxCompletion", milliseconds: Double(callbackStarted - metadata.startedNs) / 1_000_000)
    metrics.event("encoderCallbackInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    _ = lock.withLock { pending.removeValue(forKey: metadata.timestampNs) }
    if flags.contains(.frameDropped), status == noErr {
      metrics.increment("encoderDroppedFrames")
      metrics.trace("encoderOutput", "\(callbackStarted) ts=\(metadata.timestampNs) result=vtDropped")
      return
    }
    guard status == noErr, let buffer, CMSampleBufferDataIsReady(buffer) else {
      metrics.increment("encodeErrors")
      metrics.label("lastEncodeError", "VideoToolbox callback status: \(status)")
      return
    }
    if metadata.keyframeAttempt != nil, lock.withLock({ dropCheck })?.consume() == true {
      // Discard a real forced output at the same completion boundary where VT
      // can report a drop. Keep injected loss distinct from hardware drop counts.
      metrics.increment("injectedEncoderKeyframeDrops")
      metrics.trace("encoderOutput", "\(callbackStarted) ts=\(metadata.timestampNs) result=discarded")
      return
    }
    let timestamp = metadata.timestampNs
    do {
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
      let keyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
      guard let block = buffer.dataBuffer, let format = buffer.formatDescription else {
        throw ScreenSharingError.invalid("Encoded frame has no data.")
      }
      let byteCount = CMBlockBufferGetDataLength(block)
      guard (1...NALUnitBitstream.maximumFrameBytes).contains(byteCount) else {
        throw ScreenSharingError.invalid("Invalid encoded frame size.")
      }
      var bytes = Data(count: byteCount)
      let copyStatus = bytes.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
      }
      try check(copyStatus, "Read encoded frame")
      var data = Data()
      var lengthSize: Int32 = 0
      var parameterCount = 0
      try check(
        parameterSet(format, index: 0, pointer: nil, size: nil, count: &parameterCount, length: &lengthSize),
        "Read \(codec.payloadName) configuration")
      if codec != .h264 {
        let actual = try ScreenSharingHEVCFormat.read(format)
        try actual.validate(for: codec)
        metrics.label("encodedHEVCProfileIDC", String(actual.profile))
        metrics.label("encodedChroma", actual.chroma == 3 ? "4:4:4" : "4:2:0")
        metrics.label("encodedBitDepth", String(actual.lumaDepth))
      }
      if keyFrame {
        for index in 0..<parameterCount {
          var pointer: UnsafePointer<UInt8>?
          var length = 0
          try check(
            parameterSet(format, index: index, pointer: &pointer, size: &length, count: nil, length: nil),
            "Read \(codec.payloadName) parameter set")
          if let pointer { data.append(contentsOf: [0, 0, 0, 1]); data.append(pointer, count: length) }
        }
      }
      // Content identity for the viewer's idle delivery audit; precedes the slices.
      data.append(contentsOf: [0, 0, 0, 1])
      data.append(ScreenSharingSourceMarker.nalUnit(timestampNs: metadata.sourceTimestampNs, codec: codec))
      data.append(try NALUnitBitstream.annexB(bytes, lengthSize: Int(lengthSize)))
      metrics.increment("encodedFrames")
      metrics.increment("encodedBytes", by: data.count)
      metrics.increment(keyFrame ? "encodedKeyFrames" : "encodedDeltaFrames")
      metrics.increment(keyFrame ? "encodedKeyFrameBytes" : "encodedDeltaFrameBytes", by: data.count)
      metrics.observe("encode", milliseconds: Double(ScreenSharingMetrics.nowNs - metadata.startedNs) / 1_000_000)
      metrics.observe(
        "encodedOutputPreparation", milliseconds: Double(ScreenSharingMetrics.nowNs - callbackStarted) / 1_000_000)
      let callback = lock.withLock { output }
      callback?(
        ScreenSharingEncodedFrame(
          data: data, timestampNs: timestamp, rtpTimestamp: metadata.rtpTimestamp,
          width: configuration.width, height: configuration.height, isKeyFrame: keyFrame,
          sourceTimestampNs: metadata.sourceTimestampNs))
      producedKeyFrame = keyFrame && callback != nil
      metrics.trace(
        "encoderOutput",
        "\(callbackStarted) ts=\(timestamp) id=\(metadata.sourceTimestampNs) key=\(keyFrame) delivered=\(callback != nil)"
      )
    } catch { metrics.increment("encodeErrors"); metrics.label("lastEncodeError", error.localizedDescription) }
  }

  private func finishKeyframeAttempt(_ metadata: Pending, producedKeyFrame: Bool) {
    let retry = lock.withLock {
      keyframeRequest.complete(metadata.keyframeAttempt, producedKeyFrame: producedKeyFrame)
    }
    if retry { metrics.increment("encoderRetriedKeyframes") }
  }

  private func parameterSet(
    _ format: CMFormatDescription, index: Int, pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    size: UnsafeMutablePointer<Int>?, count: UnsafeMutablePointer<Int>?, length: UnsafeMutablePointer<Int32>?
  ) -> OSStatus {
    if codec == .h264 {
      return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: index,
        parameterSetPointerOut: pointer, parameterSetSizeOut: size, parameterSetCountOut: count,
        nalUnitHeaderLengthOut: length)
    }
    return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
      format, parameterSetIndex: index,
      parameterSetPointerOut: pointer, parameterSetSizeOut: size, parameterSetCountOut: count,
      nalUnitHeaderLengthOut: length)
  }

  private func property(_ key: CFString, _ value: CFTypeRef) throws {
    guard let session else { throw ScreenSharingError.unavailable("Encoder stopped.") }
    try check(VTSessionSetProperty(session, key: key, value: value), "Set encoder \(key)")
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ScreenSharingError.codec(operation, status) }
  }
}
