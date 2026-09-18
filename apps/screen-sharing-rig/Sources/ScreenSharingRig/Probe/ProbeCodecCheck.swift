import ScreenSharing
import ScreenSharingDiagnostics
import Foundation
import VideoToolbox

/// Isolated hardware experiment. No WebRTC, capture permission, private codec
/// identifiers or software fallback. Unsupported cases are reported individually.
enum ProbeCodecCheck {
  struct Variant {
    let name: String
    let codec: CMVideoCodecType
    let profile: CFString?
    let lowLatency: Bool
    var nv24 = false
    var advertised444 = false
    var prioritizeSpeed = false
    var nv12 = false
  }
  struct Result: Encodable {
    let name: String
    let completedRoundTrip: Bool
    let error: String?
    let rgbRMSE: Double?
    let metrics: ScreenSharingMetrics.Snapshot
  }
  struct Report: Encodable {
    let operatingSystem: String
    let configuration: ScreenSharingVideoConfiguration
    let note =
      "180 paced frames per case; first 60 excluded from timings. Two frames in flight. Hardware required. No network or presentation latency. RGB RMSE measures frame 90, including color conversion. HEVC output chroma is read from hvcC, not inferred from input."
    let results: [Result]
  }

  static func run(configuration: ScreenSharingVideoConfiguration, report: URL?, caseName: String?) throws {
    var variants = [
      Variant(
        name: "h264-low-delay", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: true),
      Variant(
        name: "h264-low-delay-speed", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: true, prioritizeSpeed: true),
      Variant(
        name: "h264-realtime", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: false),
      Variant(
        name: "h264-realtime-speed", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: false, prioritizeSpeed: true),
      Variant(
        name: "h264-low-delay-nv12", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: true, nv12: true),
      Variant(
        name: "h264-realtime-nv12", codec: kCMVideoCodecType_H264,
        profile: kVTProfileLevel_H264_Baseline_AutoLevel, lowLatency: false, nv12: true),
      Variant(
        name: "hevc-main", codec: kCMVideoCodecType_HEVC,
        profile: kVTProfileLevel_HEVC_Main_AutoLevel, lowLatency: false),
      Variant(name: "hevc-auto", codec: kCMVideoCodecType_HEVC, profile: nil, lowLatency: false),
      Variant(name: "hevc-low-delay", codec: kCMVideoCodecType_HEVC, profile: nil, lowLatency: true),
      Variant(name: "hevc-nv24", codec: kCMVideoCodecType_HEVC, profile: nil, lowLatency: false, nv24: true),
      Variant(name: "hevc-nv24-low-delay", codec: kCMVideoCodecType_HEVC, profile: nil, lowLatency: true, nv24: true),
      Variant(
        name: "hevc-advertised444-bgra", codec: kCMVideoCodecType_HEVC, profile: nil, lowLatency: false,
        advertised444: true),
      Variant(
        name: "hevc-main42210", codec: kCMVideoCodecType_HEVC,
        profile: kVTProfileLevel_HEVC_Main42210_AutoLevel, lowLatency: false),
    ]
    if let caseName {
      variants = variants.filter { $0.name == caseName }
      guard !variants.isEmpty else { throw ScreenSharingError.invalid("Unknown codec case: \(caseName)") }
    }
    let images = report.map { URL(fileURLWithPath: $0.path + ".images", isDirectory: true) }
    if let images { try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true) }
    var results: [Result] = []
    for variant in variants {
      let runner = CodecRunner(configuration: configuration, variant: variant)
      var failure: String?
      do { try runner.run(images: images) } catch { failure = error.localizedDescription }
      runner.stop()
      let metrics = runner.metrics.snapshot()
      let completed =
        failure == nil && metrics.counters["decodedFrames", default: 0] >= 90
        && metrics.counters["codecErrors", default: 0] == 0
      results.append(
        Result(
          name: variant.name, completedRoundTrip: completed, error: failure,
          rgbRMSE: runner.rgbRMSE, metrics: metrics))
      print("Codec \(variant.name): \(completed ? "round trip passed" : "unsupported or failed") \(failure ?? "")")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      Report(
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        configuration: configuration, results: results))
    if let report { try data.write(to: report, options: .atomic) }
    print(String(decoding: data, as: UTF8.self))
    guard results.first?.completedRoundTrip == true else {
      throw ScreenSharingError.unavailable("The first codec control case failed; inspect the recorded results.")
    }
  }
}

private final class CodecRunner: @unchecked Sendable {
  let metrics = ScreenSharingMetrics()
  let configuration: ScreenSharingVideoConfiguration
  let variant: ProbeCodecCheck.Variant
  private let lock = NSLock()
  private let decodeQueue = DispatchQueue(label: "codevisor.codec-probe.decode")
  private var pending = 0
  private var encoder: VTCompressionSession?
  private var decoder: VTDecompressionSession?
  private var transfer: VTPixelTransferSession?
  private var saved: (source: CVPixelBuffer, decoded: CVPixelBuffer)?
  private(set) var rgbRMSE: Double?

  init(configuration: ScreenSharingVideoConfiguration, variant: ProbeCodecCheck.Variant) {
    self.configuration = configuration; self.variant = variant
  }

  func run(images: URL?) throws {
    var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if variant.lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    try check(
      VTCompressionSessionCreate(
        allocator: nil, width: Int32(configuration.width),
        height: Int32(configuration.height), codecType: variant.codec,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &encoder), "Create hardware encoder")
    guard let encoder else { throw ScreenSharingError.invalid("Missing encoder.") }
    var supported: CFDictionary?
    if VTSessionCopySupportedPropertyDictionary(encoder, supportedPropertyDictionaryOut: &supported) == noErr,
      let entry = (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String]
    {
      metrics.label("supportedProfiles", String(describing: entry))
    }
    if variant.advertised444 {
      // Select only a value returned by the public property-query API. No
      // assumption that an undeclared profile exists on another OS or encoder.
      let profileInfo =
        (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
      let profiles = profileInfo?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
      guard let profile = profiles.first(where: { $0.contains("_Main444_") }) else {
        throw ScreenSharingError.unavailable("Encoder does not advertise an 8-bit Main444 profile.")
      }
      try property(kVTCompressionPropertyKey_ProfileLevel, profile as CFString)
      metrics.label("selectedAdvertisedProfile", profile)
    }
    try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    if variant.prioritizeSpeed {
      try property(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
    }
    metrics.label("encoderSpeedPolicy", variant.prioritizeSpeed ? "prioritize speed" : "encoder default")
    if let profile = variant.profile { try property(kVTCompressionPropertyKey_ProfileLevel, profile) }
    try property(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond as CFNumber)
    try property(kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber)
    try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, (configuration.framesPerSecond * 2) as CFNumber)
    let delayStatus = VTSessionSetProperty(
      encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
    metrics.label("maxFrameDelayCountStatus", String(delayStatus))
    try property(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    try property(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
    try property(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "Prepare encoder")
    hardware(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, label: "encoderHardware")
    let started = ScreenSharingMetrics.nowNs
    for sequence in 0..<180 {
      // This is paced diagnostic traffic, not correctness-test synchronization.
      let deadline = started + Int64(sequence) * 1_000_000_000 / Int64(configuration.framesPerSecond)
      let wait = Double(deadline - ScreenSharingMetrics.nowNs) / 1_000_000_000
      if wait > 0 { Thread.sleep(forTimeInterval: wait) }
      let admitted = lock.withLock {
        if pending >= 2 { return false }; pending += 1; return true
      }
      guard admitted else { metrics.increment("admissionDrops"); continue }
      do {
        try autoreleasepool {
          let original = try ProbeCodecPattern.make(
            width: configuration.width, height: configuration.height, sequence: sequence)
          let input = try source(original)
          metrics.label("inputPixelFormatCode", String(CVPixelBufferGetPixelFormatType(input)))
          let retained = ScreenSharingVideoFrame(pixelBuffer: original, timestampNs: 0)
          let submitted = ScreenSharingMetrics.nowNs
          let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: input,
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: Int32(configuration.framesPerSecond)),
            duration: CMTime(value: 1, timescale: Int32(configuration.framesPerSecond)), frameProperties: nil,
            infoFlagsOut: nil
          ) { [self] status, flags, sample in
            defer { lock.withLock { pending -= 1 } }
            guard status == noErr, !flags.contains(.frameDropped), let sample else {
              metrics.increment(status == noErr ? "encoderDrops" : "codecErrors"); return
            }
            metrics.increment("encodedFrames")
            metrics.increment("encodedBytes", by: CMSampleBufferGetTotalSampleSize(sample))
            if sequence >= 60 {
              metrics.observe("encode", milliseconds: Double(ScreenSharingMetrics.nowNs - submitted) / 1_000_000)
            }
            decodeQueue.sync {
              do { try decode(sample, original: retained, sequence: sequence) } catch {
                metrics.increment("codecErrors"); metrics.label("decodeError", error.localizedDescription)
              }
            }
          }
          try check(status, "Submit encode")
        }
      } catch { lock.withLock { pending -= 1 }; throw error }
    }
    try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), "Drain encoder")
    decodeQueue.sync {}
    if let saved {
      rgbRMSE = ProbeCodecPattern.rgbRMSE(saved.source, saved.decoded)
      if let images {
        try ProbeCodecPattern.write(saved.source, to: images.appendingPathComponent(variant.name + "-source.png"))
        try ProbeCodecPattern.write(saved.decoded, to: images.appendingPathComponent(variant.name + "-decoded.png"))
      }
    }
  }

  func stop() {
    if let encoder {
      VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid);
      VTCompressionSessionInvalidate(encoder)
    }
    encoder = nil
    decodeQueue.sync {
      if let decoder {
        VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder)
      }
      decoder = nil
    }
    if let transfer { VTPixelTransferSessionInvalidate(transfer) }; transfer = nil
  }

  private func source(_ original: CVPixelBuffer) throws -> CVPixelBuffer {
    guard variant.nv24 || variant.nv12 else { return original }
    let started = ScreenSharingMetrics.nowNs
    if transfer == nil {
      try check(
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "Create pixel transfer")
    }
    var converted: CVPixelBuffer?
    try check(
      CVPixelBufferCreate(
        nil, configuration.width, configuration.height,
        variant.nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &converted), "Allocate YCbCr input")
    guard let transfer, let converted else { throw ScreenSharingError.invalid("Missing transfer buffer.") }
    CVBufferSetAttachment(
      converted, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      converted, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      converted, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    try check(VTPixelTransferSessionTransferImage(transfer, from: original, to: converted), "Transfer BGRA to YCbCr")
    metrics.observe("inputConversion", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    return converted
  }

  private func decode(_ sample: CMSampleBuffer, original: ScreenSharingVideoFrame, sequence: Int) throws {
    guard let format = CMSampleBufferGetFormatDescription(sample) else {
      throw ScreenSharingError.invalid("Missing format.")
    }
    if decoder == nil {
      let atoms =
        CMFormatDescriptionGetExtension(
          format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
      if let hvcc = atoms?["hvcC"] as? Data, hvcc.count >= 23 {
        metrics.label("encodedHEVCProfileIDC", String(hvcc[1] & 31))
        metrics.label("encodedChroma", ["monochrome", "4:2:0", "4:2:2", "4:4:4"][Int(hvcc[16] & 3)])
        metrics.label("encodedBitDepth", String(8 + Int(hvcc[17] & 7)))
      } else if variant.codec == kCMVideoCodecType_H264 {
        metrics.label("encodedChroma", "4:2:0 (H.264 baseline)")
      }
      try check(
        VTDecompressionSessionCreate(
          allocator: nil, formatDescription: format,
          decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
            as CFDictionary,
          imageBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
          ] as CFDictionary,
          outputCallback: nil, decompressionSessionOut: &decoder), "Create hardware decoder")
      if let decoder {
        try check(
          VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue),
          "Decoder real-time")
        hardware(
          decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, label: "decoderHardware")
      }
    }
    guard let decoder else { throw ScreenSharingError.invalid("Missing decoder.") }
    let started = ScreenSharingMetrics.nowNs
    try check(
      VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
        [self] status, flags, image, _, _ in
        guard status == noErr, !flags.contains(.frameDropped), let image else {
          metrics.increment("codecErrors"); return
        }
        metrics.increment("decodedFrames")
        if sequence >= 60 {
          metrics.observe("decode", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
        }
        if sequence == 90 { saved = (original.pixelBuffer, image) }
      }, "Decode")
  }

  private func hardware(_ session: VTSession, key: CFString, label: String) {
    var value: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value)
    let result = value?.takeRetainedValue() as? Bool
    metrics.label(
      label, status == noErr ? (result == true ? "confirmed" : "not confirmed") : "required; query status \(status)")
  }
  private func property(_ key: CFString, _ value: CFTypeRef) throws {
    guard let encoder else { throw ScreenSharingError.invalid("Missing encoder.") }
    try check(VTSessionSetProperty(encoder, key: key, value: value), "Set \(key)")
  }
  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ScreenSharingError.codec(operation, status) }
  }
}
