import Foundation
@preconcurrency import WebRTC
import ScreenSharing

/// Advertise only the codec actually implemented by these adapters. Level 5.2
/// permits the probe's 4K60 ceiling; endpoints negotiate level asymmetry.
final class ScreenSharingCodecFactory: NSObject, RTCVideoEncoderFactory, RTCVideoDecoderFactory {
  let recoveryCheck = ScreenSharingDecoderRecoveryCheck()
  let encoderDropCheck = ScreenSharingEncoderDropCheck()
  let refreshSignal = ScreenSharingRefreshSignal()
  let encoderRefreshRequest = ScreenSharingEncoderRefreshRequest()
  let sourceIdleMonitor: ScreenSharingSourceIdleMonitor
  let deliveryAudit = ScreenSharingDeliveryAudit()
  /// Receiver-only diagnostic frame-delivery audit (nil = disabled).
  let frameDeliveryAudit: ScreenSharingFrameDeliveryAudit?
  let metrics: ScreenSharingMetrics
  let useLowLatencyRateControl: Bool
  let disableLookAhead: Bool
  let maximumPendingFrames: Int
  let staticCodecRate: Bool
  let completeEachFrame: Bool
  let prioritizeSpeed: Bool
  let keyframeIntervalSeconds: Int
  let codec: ScreenSharingVideoCodec

  init(
    metrics: ScreenSharingMetrics, useLowLatencyRateControl: Bool = true, codec: ScreenSharingVideoCodec = .h264,
    disableLookAhead: Bool = false, maximumPendingFrames: Int = 2, staticCodecRate: Bool = false,
    completeEachFrame: Bool = false, prioritizeSpeed: Bool = false, keyframeIntervalSeconds: Int = 2,
    sourceIdleThresholdNs: Int64 = ScreenSharingSourceIdleMonitor.defaultThresholdNs,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit? = nil
  ) {
    self.metrics = metrics; self.useLowLatencyRateControl = useLowLatencyRateControl
    self.codec = codec
    sourceIdleMonitor = ScreenSharingSourceIdleMonitor(thresholdNs: sourceIdleThresholdNs)
    self.frameDeliveryAudit = frameDeliveryAudit
    self.disableLookAhead = disableLookAhead
    self.maximumPendingFrames = maximumPendingFrames
    self.staticCodecRate = staticCodecRate
    self.completeEachFrame = completeEachFrame
    self.prioritizeSpeed = prioritizeSpeed
    self.keyframeIntervalSeconds = keyframeIntervalSeconds
  }

  func supportedCodecs() -> [RTCVideoCodecInfo] {
    [RTCVideoCodecInfo(name: codec.payloadName, parameters: codec.sdpParameters)]
  }

  func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
    guard info.name == codec.payloadName else { return nil }
    return ScreenSharingRTCEncoder(
      metrics: metrics, useLowLatencyRateControl: useLowLatencyRateControl, codec: codec,
      disableLookAhead: disableLookAhead, maximumPendingFrames: maximumPendingFrames, staticCodecRate: staticCodecRate,
      completeEachFrame: completeEachFrame, prioritizeSpeed: prioritizeSpeed,
      keyframeIntervalSeconds: keyframeIntervalSeconds, dropCheck: encoderDropCheck,
      refreshRequest: encoderRefreshRequest, idleMonitor: sourceIdleMonitor)
  }

  func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
    guard info.name == codec.payloadName else { return nil }
    return ScreenSharingRTCDecoder(
      metrics: metrics, codec: codec, recoveryCheck: recoveryCheck, refreshSignal: refreshSignal,
      deliveryAudit: deliveryAudit, frameAudit: frameDeliveryAudit)
  }
}

/// WebRTC serializes the encoder methods; only the callback crosses VT's
/// output queue. It is copied under the lock before being invoked.
private final class ScreenSharingRTCEncoder: NSObject, RTCVideoEncoder, @unchecked Sendable {
  let metrics: ScreenSharingMetrics
  private let lock = NSLock()
  private var callback: RTCVideoEncoderCallback?
  private var encoder: ScreenSharingEncoder?
  private let useLowLatencyRateControl: Bool
  private let disableLookAhead: Bool
  private let maximumPendingFrames: Int
  private let staticCodecRate: Bool
  private let completeEachFrame: Bool
  private let prioritizeSpeed: Bool
  private let keyframeIntervalSeconds: Int
  private let codec: ScreenSharingVideoCodec
  private let dropCheck: ScreenSharingEncoderDropCheck
  private let refreshRequest: ScreenSharingEncoderRefreshRequest
  private let idleMonitor: ScreenSharingSourceIdleMonitor
  var resolutionAlignment: Int { 2 }
  var applyAlignmentToAllSimulcastLayers: Bool { true }
  var supportsNativeHandle: Bool { true }

  init(
    metrics: ScreenSharingMetrics, useLowLatencyRateControl: Bool, codec: ScreenSharingVideoCodec,
    disableLookAhead: Bool, maximumPendingFrames: Int, staticCodecRate: Bool, completeEachFrame: Bool,
    prioritizeSpeed: Bool, keyframeIntervalSeconds: Int, dropCheck: ScreenSharingEncoderDropCheck,
    refreshRequest: ScreenSharingEncoderRefreshRequest, idleMonitor: ScreenSharingSourceIdleMonitor
  ) {
    self.metrics = metrics; self.useLowLatencyRateControl = useLowLatencyRateControl
    self.codec = codec
    self.disableLookAhead = disableLookAhead
    self.maximumPendingFrames = maximumPendingFrames
    self.staticCodecRate = staticCodecRate
    self.completeEachFrame = completeEachFrame
    self.prioritizeSpeed = prioritizeSpeed
    self.keyframeIntervalSeconds = keyframeIntervalSeconds
    self.dropCheck = dropCheck
    self.refreshRequest = refreshRequest
    self.idleMonitor = idleMonitor
  }
  func implementationName() -> String { "CodevisorVideoToolbox\(codec.payloadName)" }
  func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
  func setCallback(_ callback: RTCVideoEncoderCallback?) { lock.withLock { self.callback = callback } }

  func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
    do {
      encoder?.stop()
      let configuration = try ScreenSharingVideoConfiguration(
        width: Int(settings.width), height: Int(settings.height), framesPerSecond: max(1, Int(settings.maxFramerate)),
        bitrate: max(100_000, Int(settings.startBitrate) * 1000))
      let encoder = try ScreenSharingEncoder(
        configuration: configuration, metrics: metrics, useLowLatencyRateControl: useLowLatencyRateControl,
        codec: codec,
        disableLookAhead: disableLookAhead, maximumPendingFrames: maximumPendingFrames,
        completeEachFrame: completeEachFrame, prioritizeSpeed: prioritizeSpeed,
        keyframeIntervalSeconds: keyframeIntervalSeconds
      )
      encoder.onFrame { [weak self] frame in self?.deliver(frame) }
      encoder.useDropCheck(dropCheck)
      self.encoder = encoder
      return 0
    } catch { metrics.label("encoderError", error.localizedDescription); return -1 }
  }

  func encode(
    _ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]
  ) -> Int {
    guard let encoder, let native = frame.buffer as? RTCCVPixelBuffer, !native.requiresCropping() else {
      metrics.increment("unsupportedEncoderInput"); return -1
    }
    // WebRTC translated this frame's timestamp; identity rides on the buffer.
    guard let identity = ScreenSharingFrameIdentity.required(of: native.pixelBuffer, metrics: metrics) else {
      return -1
    }
    do {
      let refresh = refreshRequest.consume()
      let requestedKey = frameTypes.contains(where: { $0.intValue == RTCFrameType.videoFrameKey.rawValue })
      metrics.trace(
        "encoderInput",
        "\(ScreenSharingMetrics.nowNs) ts=\(frame.timeStampNs) id=\(identity) latch=\(refresh) webrtcKey=\(requestedKey)"
      )
      try encoder.encode(
        ScreenSharingVideoFrame(
          pixelBuffer: native.pixelBuffer, timestampNs: frame.timeStampNs,
          rtpTimestamp: UInt32(bitPattern: frame.timeStamp), sourceTimestampNs: identity),
        forceKeyFrame: refresh || frameTypes.contains(where: { $0.intValue == RTCFrameType.videoFrameKey.rawValue }))
      return 0
    } catch { metrics.label("encoderError", error.localizedDescription); return -1 }
  }

  func release() -> Int { encoder?.stop(); encoder = nil; return 0 }

  func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
    if staticCodecRate {
      metrics.increment("encoderRateUpdatesHeld")
      metrics.label("encoderRateUpdatePolicy", "initial rate experiment")
      return 0
    }
    do {
      try encoder?.setBitrate(max(1, Int(bitrateKbit)) * 1000, framesPerSecond: min(60, max(1, Int(framerate))))
      return 0
    } catch { metrics.label("encoderError", error.localizedDescription); return -1 }
  }

  private func deliver(_ frame: ScreenSharingEncodedFrame) {
    metrics.event("encodedDeliveryInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    let image = RTCEncodedImage()
    image.buffer = frame.data
    image.encodedWidth = Int32(frame.width)
    image.encodedHeight = Int32(frame.height)
    image.timeStamp = frame.rtpTimestamp
    image.captureTimeMs = frame.timestampNs / 1_000_000
    image.frameType = frame.isKeyFrame ? .videoFrameKey : .videoFrameDelta
    image.contentType = .screenshare
    image.rotation = ._0
    let info: any RTCCodecSpecificInfo
    if codec == .h264 {
      let h264 = RTCCodecSpecificInfoH264()
      h264.packetizationMode = .nonInterleaved
      info = h264
    } else {
      info = ScreenSharingHEVCInfo()
    }
    // Qualify the property read: the new `callback` binding shadows it, which older compilers (Swift 6.3.3 on
    // Xcode 26.6) cannot infer through `withLock`. Take the snapshot under the lock, call it outside — unchanged.
    let callback = lock.withLock { self.callback }
    let started = ScreenSharingMetrics.nowNs
    _ = callback?(image, info)
    metrics.observe("encodedDeliveryCallback", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    guard callback != nil, let sourceTimestampNs = frame.sourceTimestampNs else { return }
    // Only output handed to WebRTC can be announced as the host's newest content.
    idleMonitor.recordEncoded(timestampNs: sourceTimestampNs)
    metrics.label("latestEncodedSourceTimestampNs", String(sourceTimestampNs))
  }
}

/// M152's ObjC bridge has no HEVC-specific metadata type. Its native sender
/// selects the H.265 packetizer from the negotiated payload, and parses Annex B.
private final class ScreenSharingHEVCInfo: NSObject, RTCCodecSpecificInfo {}

private final class ScreenSharingRTCDecoder: NSObject, RTCVideoDecoder, @unchecked Sendable {
  let metrics: ScreenSharingMetrics
  private let codec: ScreenSharingVideoCodec
  private let recoveryCheck: ScreenSharingDecoderRecoveryCheck
  private let refreshSignal: ScreenSharingRefreshSignal
  private let deliveryAudit: ScreenSharingDeliveryAudit
  /// Receiver-only diagnostic frame-delivery audit (nil = disabled, no work).
  private let frameAudit: ScreenSharingFrameDeliveryAudit?
  private let lock = NSLock()
  private var callback: RTCVideoDecoderCallback?
  private var decoder: ScreenSharingDecoder?

  init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec, recoveryCheck: ScreenSharingDecoderRecoveryCheck,
    refreshSignal: ScreenSharingRefreshSignal, deliveryAudit: ScreenSharingDeliveryAudit,
    frameAudit: ScreenSharingFrameDeliveryAudit?
  ) {
    self.metrics = metrics; self.codec = codec; self.recoveryCheck = recoveryCheck
    self.refreshSignal = refreshSignal
    self.deliveryAudit = deliveryAudit
    self.frameAudit = frameAudit
  }
  func implementationName() -> String { "CodevisorVideoToolbox\(codec.payloadName)" }
  func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { lock.withLock { self.callback = callback } }

  func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
    decoder?.stop()
    decoder = ScreenSharingDecoder(metrics: metrics, codec: codec, deliveryAudit: frameAudit) { [weak self] frame in
      guard let self else { return }
      if let sourceTimestampNs = frame.sourceTimestampNs {
        self.deliveryAudit.decoded(sourceTimestampNs: sourceTimestampNs)
        self.metrics.label("latestDecodedSourceTimestampNs", String(sourceTimestampNs))
        // The identity rides the decoded buffer to the renderer, as it rides the captured buffer to the encoder.
        ScreenSharingFrameIdentity.attach(sourceTimestampNs: sourceTimestampNs, to: frame.pixelBuffer)
      }
      let decoded = RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer), rotation: ._0, timeStampNs: frame.timestampNs)
      decoded.timeStamp = Int32(bitPattern: frame.rtpTimestamp)
      let callback = self.lock.withLock { self.callback }
      callback?(decoded)
    }
    decoder?.useRefreshSignal(refreshSignal)
    return 0
  }

  func decode(
    _ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
    renderTimeMs: Int64
  ) -> Int {
    guard let decoder, image.rotation == ._0 else { return -1 }
    switch recoveryCheck.inspect(
      keyFrame: image.frameType == .videoFrameKey, nowNs: ScreenSharingMetrics.nowNs)
    {
    case .accept: break
    case .reset:
      decoder.stop()
      metrics.increment("injectedDecoderResets")
      metrics.trace("decoderInput", "\(ScreenSharingMetrics.nowNs) rtp=\(image.timeStamp) key=false action=reset")
      refreshSignal.request()
      return -1
    case .rejectDelta:
      metrics.increment("recoveryDeltaFramesRejected")
      metrics.trace("decoderInput", "\(ScreenSharingMetrics.nowNs) rtp=\(image.timeStamp) key=false action=rejectDelta")
      refreshSignal.request()
      return -1
    case .recovered(let milliseconds):
      metrics.increment("recoveryKeyframesReceived")
      metrics.observe("decoderResetToRecoveryKeyframe", milliseconds: milliseconds)
      metrics.trace("decoderInput", "\(ScreenSharingMetrics.nowNs) rtp=\(image.timeStamp) key=true action=recovered")
    }
    if image.frameType == .videoFrameKey {
      metrics.trace("decoderInput", "\(ScreenSharingMetrics.nowNs) rtp=\(image.timeStamp) key=true action=accept")
    }
    metrics.event("decoderInputInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    // decoder input after WebRTC reassembly/release
    let auditIdentity = frameAudit?.decoderInput(rtpTimestamp: image.timeStamp)
    do {
      try decoder.decode(
        ScreenSharingEncodedFrame(
          data: image.buffer, timestampNs: renderTimeMs * 1_000_000, rtpTimestamp: image.timeStamp,
          width: Int(image.encodedWidth), height: Int(image.encodedHeight),
          isKeyFrame: image.frameType == .videoFrameKey), auditIdentity: auditIdentity)
      return 0
    } catch {
      decoder.stop()
      refreshSignal.request()
      metrics.label("decoderError", error.localizedDescription)
      return -1
    }
  }

  func release() -> Int { decoder?.stop(); decoder = nil; return 0 }
}
