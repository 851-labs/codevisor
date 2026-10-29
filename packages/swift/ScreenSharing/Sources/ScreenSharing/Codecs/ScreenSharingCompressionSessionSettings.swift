import CoreMedia
import Foundation
import VideoToolbox

struct ScreenSharingCompressionSessionSettings {
  let configuration: ScreenSharingVideoConfiguration
  let codec: ScreenSharingVideoCodec
  let dynamicRange: ScreenSharingDynamicRange
  let useLowLatencyRateControl: Bool
  let prioritizeSpeed: Bool
  let keyframeIntervalSeconds: Int
  let metrics: ScreenSharingMetrics

  func open(bitrate: Int, framesPerSecond: Int) throws -> VTCompressionSession {
    let created = try create()
    do {
      try configureSpeed(created)
      try configureProfile(created)
      try configureRateAndColor(created, bitrate: bitrate, framesPerSecond: framesPerSecond)
      try check(VTCompressionSessionPrepareToEncodeFrames(created), "Prepare encoder")
      try confirmHardware(created)
      return created
    } catch {
      VTCompressionSessionInvalidate(created)
      throw error
    }
  }

  private func create() throws -> VTCompressionSession {
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
    return created
  }

  private func configureSpeed(_ created: VTCompressionSession) throws {
    try set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    if prioritizeSpeed {
      try set(created, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
    }
    metrics.label("encoderSpeedPolicy", prioritizeSpeed ? "prioritize speed" : "encoder default")
    metrics.label("encoderRateControl", useLowLatencyRateControl ? "low latency" : "standard")
  }

  private func configureProfile(_ created: VTCompressionSession) throws {
    if codec == .hevc444 {
      var supported: CFDictionary?
      try check(
        VTSessionCopySupportedPropertyDictionary(created, supportedPropertyDictionaryOut: &supported),
        "Read encoder properties")
      let profileInfo =
        (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
      let profiles = profileInfo?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
      let wanted = dynamicRange == .high ? "_Main44410_" : "_Main444_"
      guard let profile = profiles.first(where: { $0.contains(wanted) }) else {
        throw ScreenSharingError.unavailable(
          "Hardware encoder does not advertise a \(dynamicRange == .high ? "10" : "8")-bit Main444 profile.")
      }
      try set(created, kVTCompressionPropertyKey_ProfileLevel, profile as CFString)
      metrics.label("encoderProfile", profile)
    } else {
      try set(
        created,
        kVTCompressionPropertyKey_ProfileLevel,
        codec == .h264 ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
    }
  }

  private func configureRateAndColor(
    _ created: VTCompressionSession, bitrate: Int, framesPerSecond: Int
  ) throws {
    try set(created, kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
    try set(created, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
    try set(
      created,
      kVTCompressionPropertyKey_MaxKeyFrameInterval,
      (configuration.framesPerSecond * keyframeIntervalSeconds) as CFNumber)
    if dynamicRange == .high {
      try set(created, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_P3_D65)
      try set(created, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    } else {
      try set(created, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
      try set(created, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    }
    try set(created, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  }

  private func confirmHardware(_ created: VTCompressionSession) throws {
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
    metrics.label("encoderHardware", hardwareStatus == noErr ? "confirmed" : "required; query unsupported")
    metrics.label("encoder", "VideoToolbox \(codec.rawValue) hardware, no frame reordering")
    metrics.label(
      "encodedColor", dynamicRange == .high ? "Display P3 primaries, PQ transfer" : "BT.709 primaries, sRGB transfer")
  }

  private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
    try check(VTSessionSetProperty(session, key: key, value: value), "Set encoder \(key)")
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw ScreenSharingError.codec(operation, status) }
  }
}
