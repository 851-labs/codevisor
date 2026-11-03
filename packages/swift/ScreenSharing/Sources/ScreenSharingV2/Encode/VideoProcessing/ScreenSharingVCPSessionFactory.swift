import CoreMedia
import ScreenSharing
import VideoToolbox

struct ScreenSharingVCPSessionFactory {
  let width: Int
  let height: Int
  let framesPerSecond: Int
  let rate: ScreenSharingVCPRate

  func make() throws -> ScreenSharingVCPSession {
    let api = try ScreenSharingVideoProcessing.load()
    let sink = ScreenSharingVCPOutputSink()
    let refcon = Unmanaged.passRetained(sink)
    let session: ScreenSharingVCPSession
    do {
      session = ScreenSharingVCPSession(
        api: api, session: try create(api, refcon: refcon), sink: sink, refcon: refcon,
        framesPerSecond: framesPerSecond)
    } catch {
      refcon.release()
      throw error
    }
    return try configured(session)
  }

  private func configured(_ session: ScreenSharingVCPSession) throws -> ScreenSharingVCPSession {
    do {
      try configure(session)
      return session
    } catch {
      session.close()
      throw error
    }
  }

  private func create(
    _ api: ScreenSharingVideoProcessing, refcon: Unmanaged<ScreenSharingVCPOutputSink>
  ) throws
    -> AnyObject
  {
    var created: Unmanaged<AnyObject>?
    let status = api.create(
      kCFAllocatorDefault, Int32(width), Int32(height), kCMVideoCodecType_HEVC,
      specification(api.keys) as CFDictionary, sourceAttributes as CFDictionary, nil,
      ScreenSharingVCPOutputSink.callback, refcon.toOpaque(), &created)
    guard status == noErr else { throw ScreenSharingError.codec("Create VCP encoder", status) }
    guard let session = created?.takeRetainedValue() else { throw ScreenSharingError.unavailable("No VCP encoder.") }

    return session
  }

  private func specification(_ keys: ScreenSharingVCPKeys) -> [CFString: Any] {
    [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
      keys.usage: ScreenSharingVCPKeys.usage,
      ScreenSharingVCPKeys.realTime: true,
      kVTCompressionPropertyKey_ProfileLevel: ScreenSharingVCPKeys.main444,
    ]
  }

  private var sourceAttributes: [CFString: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey: ScreenSharingVCPPixelConverter.encodedPixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
  }

  private func configure(_ session: ScreenSharingVCPSession) throws {
    try session.set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try session.set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try session.set(kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
    try session.set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 0 as CFNumber)
    try session.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, ScreenSharingVCPRate.highestFrameQP as CFNumber)
    try session.setBitrate(rate.tileBitsPerSecond, windowBitsPerSecond: rate.tileWindowBitsPerSecond)
    try session.set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    try session.set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    try session.set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  }
}
