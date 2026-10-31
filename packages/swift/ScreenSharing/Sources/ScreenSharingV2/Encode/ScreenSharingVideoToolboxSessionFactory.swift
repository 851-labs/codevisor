import CoreMedia
import ScreenSharing
import VideoToolbox

struct ScreenSharingVideoToolboxSessionFactory {
  let width: Int
  let height: Int
  let framesPerSecond: Int
  let bitrate: Int

  func make() throws -> VTCompressionSession {
    let session = try create()
    do {
      try configure(session)
      try check(VTCompressionSessionPrepareToEncodeFrames(session), "Prepare encoder")
      try confirmHardware(session)
      return session
    } catch {
      VTCompressionSessionInvalidate(session)
      throw error
    }
  }

  private func create() throws -> VTCompressionSession {
    var created: VTCompressionSession?
    try check(
      VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
        codecType: ScreenSharingV2Profile.codec.mediaType, encoderSpecification: specification,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &created), "Create encoder")
    guard let created else { throw ScreenSharingError.unavailable("No hardware HEVC encoder.") }

    return created
  }

  private var specification: CFDictionary {
    [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
      kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
    ] as CFDictionary
  }

  private func configure(_ session: VTCompressionSession) throws {
    try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
    try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
    try set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
    try set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, 0 as CFNumber)
    try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0 as CFNumber)
    try set(session, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
    try set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    try set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    try set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  }

  private func confirmHardware(_ session: VTCompressionSession) throws {
    var hardware: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(
      session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil,
      valueOut: &hardware)
    let usesHardware = hardware?.takeRetainedValue() as? Bool
    guard status != noErr || usesHardware == true else {
      throw ScreenSharingError.unavailable("The HEVC encoder is not hardware backed.")
    }
  }

  private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
    try check(VTSessionSetProperty(session, key: key, value: value), "Set encoder \(key)")
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ScreenSharingError.codec(operation, status) }
  }
}
