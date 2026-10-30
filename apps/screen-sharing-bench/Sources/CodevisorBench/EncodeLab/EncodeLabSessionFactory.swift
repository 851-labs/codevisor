import CoreMedia
import ScreenSharing
import VideoToolbox

struct EncodeLabSessionFactory {
  let config: EncodeLabConfig
  let width: Int
  let height: Int

  func make() throws -> VTCompressionSession {
    let session = try create()
    do {
      try EncodeLabSessionProperties(config: config, target: EncodeLabVTPropertyTarget(session: session)).apply()
      try check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")
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
        codecType: config.codec.video.mediaType, encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &created), "create")
    guard let created else { throw EncodeLabError.encoder("create", -1) }

    return created
  }

  private var specification: [CFString: Any] {
    var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if config.rateControl == .lowLatency {
      specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
    }
    return specification
  }

  private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw EncodeLabError.encoder(step, status) }
  }
}
