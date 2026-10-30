import CoreMedia
import ScreenSharing
import VideoToolbox

struct EncodeLabSessionProperties {
  static let framesPerSecond = 60
  static let keyframeIntervalSeconds = 60

  let config: EncodeLabConfig
  let session: VTCompressionSession

  func apply() throws {
    if let preset = config.preset { try applyPreset(preset) }
    try applySpeed()
    try applyProfile()
    try applyRate()
    try applyColor()
    try applyOptional()
  }

  private func applyPreset(_ name: String) throws {
    let preset = EncodeLabPreset.key(named: name)
    let presets = try supportedPresets()
    guard let settings = presets[preset as String] else {
      throw EncodeLabError.missingPreset(name, presets.keys.sorted())
    }

    let status = VTSessionSetProperties(session, propertyDictionary: settings as CFDictionary)
    guard status == noErr else { throw EncodeLabError.property("preset \(name)", status) }
  }

  private func supportedPresets() throws -> [String: [String: Any]] {
    var value: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(
      session, key: kVTCompressionPropertyKey_SupportedPresetDictionaries, allocator: nil, valueOut: &value)
    guard status == noErr else { throw EncodeLabError.property("SupportedPresetDictionaries", status) }

    return value?.takeRetainedValue() as? [String: [String: Any]] ?? [:]
  }

  private func applySpeed() throws {
    try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    guard config.prioritizesSpeed else { return }

    try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
  }

  private func applyProfile() throws {
    switch config.codec {
    case .hevc444: try set(kVTCompressionPropertyKey_ProfileLevel, try main444Profile() as CFString)
    case .hevc: try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
    case .h264: try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
    }
  }

  private func main444Profile() throws -> String {
    var supported: CFDictionary?
    let status = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported)
    guard status == noErr else { throw EncodeLabError.property("supported properties", status) }

    let info = (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
    let profiles = info?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
    guard let profile = profiles.first(where: { $0.contains("_Main444_") }) else {
      throw EncodeLabError.property("Main444 profile", kVTPropertyNotSupportedErr)
    }

    return profile
  }

  private func applyRate() throws {
    try set(kVTCompressionPropertyKey_ExpectedFrameRate, Self.framesPerSecond as CFNumber)
    try set(
      kVTCompressionPropertyKey_MaxKeyFrameInterval, (Self.framesPerSecond * Self.keyframeIntervalSeconds) as CFNumber)
    if let bits = config.tileBitsPerSecond { try set(kVTCompressionPropertyKey_AverageBitRate, bits as CFNumber) }
    guard let limit = config.rateLimit, let bytes = config.tileRateLimitBytes else { return }

    let limits = [bytes as CFNumber, limit.windowSeconds as CFNumber] as CFArray
    try set(kVTCompressionPropertyKey_DataRateLimits, limits)
  }

  private func applyColor() throws {
    try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  }

  private func applyOptional() throws {
    if let delay = config.maxFrameDelay { try set(kVTCompressionPropertyKey_MaxFrameDelayCount, delay as CFNumber) }
    if let qp = config.maxQP { try set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber) }
    if let qp = config.minQP { try set(kVTCompressionPropertyKey_MinAllowedFrameQP, qp as CFNumber) }
    if let adaptive = config.spatialAdaptiveQP {
      let level = adaptive ? kVTQPModulationLevel_Default : kVTQPModulationLevel_Disable
      try set(kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, level as CFNumber)
    }
    if config.longTermReferences { try set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }
    if let quality = config.constantQuality { try applyConstantQuality(quality) }
  }

  private func applyConstantQuality(_ quality: Double) throws {
    guard #available(macOS 27.0, *) else {
      throw EncodeLabError.property("ConstantQualityFactor", kVTPropertyNotSupportedErr)
    }

    try set(kVTCompressionPropertyKey_ConstantQualityFactor, quality as CFNumber)
  }

  private func set(_ key: CFString, _ value: CFTypeRef) throws {
    let status = VTSessionSetProperty(session, key: key, value: value)
    guard status == noErr else { throw EncodeLabError.property(key as String, status) }
  }
}
