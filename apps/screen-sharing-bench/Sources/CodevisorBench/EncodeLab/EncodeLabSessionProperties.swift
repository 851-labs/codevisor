import CoreMedia
import ScreenSharing
import ScreenSharingWebRTC
import VideoToolbox

struct EncodeLabSessionProperties {
  static let framesPerSecond = 60
  static let keyframeIntervalSeconds = ScreenSharingProductProfile.keyframeIntervalSeconds

  let config: EncodeLabConfig
  let target: any EncodeLabPropertyTarget

  func apply() throws {
    if let preset = config.preset { try applyPreset(preset) }
    try applySpeed()
    try applyProfile()
    try applyRate()
    try applyColor()
    try applyOptional()
  }

  private func applyPreset(_ name: String) throws {
    let presets = try supportedPresets()
    guard let settings = presets[EncodeLabPreset.key(named: name) as String] else {
      throw EncodeLabError.missingPreset(name, presets.keys.sorted())
    }

    for (key, value) in settings { try set(key as CFString, value as CFTypeRef) }
  }

  private func supportedPresets() throws -> [String: [String: Any]] {
    let (status, value) = target.copy(kVTCompressionPropertyKey_SupportedPresetDictionaries)
    guard status == noErr else { throw EncodeLabError.property("SupportedPresetDictionaries", status) }

    return value as? [String: [String: Any]] ?? [:]
  }

  private func applySpeed() throws {
    try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    guard config.prioritizeSpeed else { return }

    try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
  }

  private func applyProfile() throws {
    switch config.codec {
    case .hevc444: try set(kVTCompressionPropertyKey_ProfileLevel, try target.main444Profile())
    case .hevc: try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
    case .h264: try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
    }
  }

  private func applyRate() throws {
    try set(kVTCompressionPropertyKey_ExpectedFrameRate, Self.framesPerSecond as CFNumber)
    try set(
      kVTCompressionPropertyKey_MaxKeyFrameInterval, (Self.framesPerSecond * Self.keyframeIntervalSeconds) as CFNumber)
    if let bits = config.sessionBitsPerSecond { try set(kVTCompressionPropertyKey_AverageBitRate, bits as CFNumber) }
    guard let limit = config.rateLimit, let bytes = config.sessionRateLimitBytes else { return }

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
    let status = target.set(key, value)
    guard status == noErr else { throw EncodeLabError.property(key as String, status) }
  }
}
