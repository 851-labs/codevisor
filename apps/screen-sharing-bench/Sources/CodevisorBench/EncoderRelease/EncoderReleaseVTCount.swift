import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncoderReleaseVTCount: Codable {
  static let tileWidth = 1920
  static let tileHeight = 544

  let working: Int
  let stoppedBy: String

  static func measure(limit: Int) throws -> EncoderReleaseVTCount {
    let frame = try picture()
    var sessions: [VTCompressionSession] = []
    defer { sessions.forEach { VTCompressionSessionInvalidate($0) } }
    for _ in 0..<limit {
      let (session, failure) = open()
      guard let session else { return EncoderReleaseVTCount(working: sessions.count, stoppedBy: failure) }

      sessions.append(session)
      let status = encode(frame, with: session)
      guard status == noErr else {
        return EncoderReleaseVTCount(working: sessions.count - 1, stoppedBy: "encode \(status)")
      }
    }
    return EncoderReleaseVTCount(working: sessions.count, stoppedBy: "limit")
  }

  private static func open() -> (VTCompressionSession?, String) {
    let specification =
      [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
      ] as CFDictionary
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(tileWidth), height: Int32(tileHeight), codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard status == noErr, let session else { return (nil, "create \(status)") }

    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    return (session, "")
  }

  private static func encode(_ frame: CVPixelBuffer, with session: VTCompressionSession) -> OSStatus {
    let result = EncoderReleaseStatus()
    let submitted = VTCompressionSessionEncodeFrame(
      session, imageBuffer: frame, presentationTimeStamp: .zero, duration: .invalid, frameProperties: nil,
      infoFlagsOut: nil
    ) { status, _, _ in result.finish(status) }
    guard submitted == noErr else { return submitted }

    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return result.wait()
  }

  private static func picture() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    let status = CVPixelBufferCreate(
      nil, tileWidth, tileHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw BenchUsageError(message: "no pixel buffer (\(status))") }

    return buffer
  }
}
