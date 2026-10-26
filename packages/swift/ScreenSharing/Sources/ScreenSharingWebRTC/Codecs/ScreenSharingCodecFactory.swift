import Foundation
import VideoToolbox
@preconcurrency import WebRTC
import ScreenSharing

final class ScreenSharingCodecFactory: NSObject, RTCVideoEncoderFactory, RTCVideoDecoderFactory {
  let refreshSignal = ScreenSharingRefreshSignal()
  let encoderRefreshRequest = ScreenSharingEncoderRefreshRequest()
  let sourceIdleMonitor = ScreenSharingSourceIdleMonitor()
  let deliveryAudit = ScreenSharingDeliveryAudit()
  let metrics: ScreenSharingMetrics
  let codecs: [ScreenSharingVideoCodec]
  var codec: ScreenSharingVideoCodec { codecs[0] }

  init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec = .h264,
    fallbackCodecs: [ScreenSharingVideoCodec] = []
  ) {
    self.metrics = metrics
    codecs = Self.decodable(Self.negotiable(primary: codec, fallbacks: fallbackCodecs))
  }

  static func negotiable(
    primary: ScreenSharingVideoCodec, fallbacks: [ScreenSharingVideoCodec]
  ) -> [ScreenSharingVideoCodec] {
    var codecs = [primary]
    for fallback in fallbacks where !codecs.contains(fallback) { codecs.append(fallback) }
    return codecs
  }

  static func decodable(
    _ codecs: [ScreenSharingVideoCodec],
    hardwareDecodes: (CMVideoCodecType) -> Bool = { VTIsHardwareDecodeSupported($0) }
  ) -> [ScreenSharingVideoCodec] {
    let usable = codecs.filter { $0 == .h264 || hardwareDecodes($0.mediaType) }
    return usable.isEmpty ? [.h264] : usable
  }

  static func rateControl(for codec: ScreenSharingVideoCodec) -> (lowLatency: Bool, prioritizeSpeed: Bool) {
    guard codec == .hevc444 else { return (true, false) }
    return (false, true)
  }

  func supportedCodecs() -> [RTCVideoCodecInfo] {
    codecs.map { RTCVideoCodecInfo(name: $0.payloadName, parameters: $0.sdpParameters) }
  }

  func codec(for info: RTCVideoCodecInfo) -> ScreenSharingVideoCodec? {
    let candidates = codecs.filter { $0.payloadName == info.name }
    guard candidates.count > 1 || info.name == "H265" else { return candidates.first }
    let profile = info.parameters["profile-id"] ?? "1"
    return candidates.first { $0.sdpParameters["profile-id"] == profile }
  }

  func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
    guard let codec = codec(for: info) else { return nil }
    metrics.label("videoCodec", codec.rawValue)
    return ScreenSharingRTCEncoder(
      metrics: metrics, codec: codec, refreshRequest: encoderRefreshRequest, idleMonitor: sourceIdleMonitor)
  }

  func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
    guard let codec = codec(for: info) else { return nil }
    metrics.label("videoCodec", codec.rawValue)
    return ScreenSharingRTCDecoder(
      metrics: metrics, codec: codec, refreshSignal: refreshSignal, deliveryAudit: deliveryAudit)
  }
}

private final class ScreenSharingRTCEncoder: NSObject, RTCVideoEncoder, @unchecked Sendable {
  let metrics: ScreenSharingMetrics
  private let lock = NSLock()
  private var callback: RTCVideoEncoderCallback?
  private var encoder: ScreenSharingEncoder?
  private let codec: ScreenSharingVideoCodec
  private let refreshRequest: ScreenSharingEncoderRefreshRequest
  private let idleMonitor: ScreenSharingSourceIdleMonitor
  private static let maximumPendingFrames = 3
  private static let keyframeIntervalSeconds = 60
  var resolutionAlignment: Int { 2 }
  var applyAlignmentToAllSimulcastLayers: Bool { true }
  var supportsNativeHandle: Bool { true }

  init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec,
    refreshRequest: ScreenSharingEncoderRefreshRequest, idleMonitor: ScreenSharingSourceIdleMonitor
  ) {
    self.metrics = metrics
    self.codec = codec
    self.refreshRequest = refreshRequest
    self.idleMonitor = idleMonitor
  }
  func implementationName() -> String { "CodevisorVideoToolbox\(codec.payloadName)" }
  func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
  func setCallback(_ callback: RTCVideoEncoderCallback?) { lock.withLock { self.callback = callback } }

  private var configuration: ScreenSharingVideoConfiguration?

  func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
    do {
      encoder?.stop()
      let configuration = try ScreenSharingVideoConfiguration(
        width: Int(settings.width), height: Int(settings.height), framesPerSecond: max(1, Int(settings.maxFramerate)),
        bitrate: max(100_000, Int(settings.startBitrate) * 1000))
      self.configuration = configuration
      encoder = try makeEncoder(configuration, dynamicRange: encoder?.dynamicRange ?? .standard)
      return 0
    } catch { metrics.label("encoderError", error.localizedDescription); return -1 }
  }

  private func makeEncoder(
    _ configuration: ScreenSharingVideoConfiguration, dynamicRange: ScreenSharingDynamicRange
  ) throws -> ScreenSharingEncoder {
    let rateControl = ScreenSharingCodecFactory.rateControl(for: codec)
    let encoder = try ScreenSharingEncoder(
      configuration: configuration, metrics: metrics, useLowLatencyRateControl: rateControl.lowLatency, codec: codec,
      maximumPendingFrames: Self.maximumPendingFrames, prioritizeSpeed: rateControl.prioritizeSpeed,
      keyframeIntervalSeconds: Self.keyframeIntervalSeconds, dynamicRange: dynamicRange
    )
    encoder.onFrame { [weak self] frame in self?.deliver(frame) }
    return encoder
  }

  private func follow(_ range: ScreenSharingDynamicRange) throws -> ScreenSharingEncoder? {
    guard let encoder, encoder.dynamicRange != range, let configuration else { return encoder }
    encoder.stop()
    self.encoder = nil
    let rebuilt = try makeEncoder(configuration, dynamicRange: range)
    self.encoder = rebuilt
    metrics.increment("encoderDynamicRangeSwitches")
    metrics.label("encoderDynamicRange", range.rawValue)
    return rebuilt
  }

  func encode(
    _ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]
  ) -> Int {
    guard self.encoder != nil, let native = frame.buffer as? RTCCVPixelBuffer, !native.requiresCropping() else {
      metrics.increment("unsupportedEncoderInput"); return -1
    }
    let range = ScreenSharingDynamicRange(pixelFormat: CVPixelBufferGetPixelFormatType(native.pixelBuffer))
    let encoder: ScreenSharingEncoder
    do {
      guard let current = try follow(range) else { return -1 }
      encoder = current
    } catch { metrics.label("encoderError", error.localizedDescription); return -1 }
    guard let identity = ScreenSharingFrameIdentity.required(of: native.pixelBuffer, metrics: metrics) else {
      return -1
    }
    do {
      let refresh = refreshRequest.consume()
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
    do {
      let bitrate = max(1, Int(bitrateKbit)) * 1000
      let framesPerSecond = min(60, max(1, Int(framerate)))
      try encoder?.setBitrate(bitrate, framesPerSecond: framesPerSecond)
      if let configuration {
        self.configuration =
          (try? ScreenSharingVideoConfiguration(
            width: configuration.width, height: configuration.height, framesPerSecond: framesPerSecond,
            bitrate: min(80_000_000, max(100_000, bitrate)))) ?? configuration
      }
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
    let callback = lock.withLock { self.callback }
    let started = ScreenSharingMetrics.nowNs
    _ = callback?(image, info)
    metrics.observe("encodedDeliveryCallback", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    guard callback != nil, let sourceTimestampNs = frame.sourceTimestampNs else { return }
    idleMonitor.recordEncoded(timestampNs: sourceTimestampNs)
    metrics.label("latestEncodedSourceTimestampNs", String(sourceTimestampNs))
  }
}

private final class ScreenSharingHEVCInfo: NSObject, RTCCodecSpecificInfo {}

private final class ScreenSharingRTCDecoder: NSObject, RTCVideoDecoder, @unchecked Sendable {
  let metrics: ScreenSharingMetrics
  private let codec: ScreenSharingVideoCodec
  private let refreshSignal: ScreenSharingRefreshSignal
  private let deliveryAudit: ScreenSharingDeliveryAudit
  private let lock = NSLock()
  private var callback: RTCVideoDecoderCallback?
  private var decoder: ScreenSharingDecoder?

  init(
    metrics: ScreenSharingMetrics, codec: ScreenSharingVideoCodec, refreshSignal: ScreenSharingRefreshSignal,
    deliveryAudit: ScreenSharingDeliveryAudit
  ) {
    self.metrics = metrics; self.codec = codec
    self.refreshSignal = refreshSignal
    self.deliveryAudit = deliveryAudit
  }
  func implementationName() -> String { "CodevisorVideoToolbox\(codec.payloadName)" }
  func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { lock.withLock { self.callback = callback } }

  func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
    decoder?.stop()
    decoder = ScreenSharingDecoder(metrics: metrics, codec: codec) { [weak self] frame in
      guard let self else { return }
      if let sourceTimestampNs = frame.sourceTimestampNs {
        self.deliveryAudit.decoded(sourceTimestampNs: sourceTimestampNs)
        self.metrics.label("latestDecodedSourceTimestampNs", String(sourceTimestampNs))
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
    metrics.event("decoderInputInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    do {
      try decoder.decode(
        ScreenSharingEncodedFrame(
          data: image.buffer, timestampNs: renderTimeMs * 1_000_000, rtpTimestamp: image.timeStamp,
          width: Int(image.encodedWidth), height: Int(image.encodedHeight),
          isKeyFrame: image.frameType == .videoFrameKey))
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
