import CoreMedia
import Foundation
import ScreenSharing
import VideoToolbox

public enum ScreenSharingV2Chroma: String, Sendable {
  case full = "444"
  case subsampled = "420"

  public static let decodable: Self = ScreenSharingV2ChromaProbe.decodesFullChroma() ? .full : .subsampled
}

enum ScreenSharingV2ChromaProbe {
  private final class Outcome: @unchecked Sendable {
    var decoded = false
  }

  static func decodesFullChroma() -> Bool {
    guard
      let format = try? ScreenSharingV2FormatDescription.make(parameterSets: parameterSets.map { Data($0) }),
      let session = try? ScreenSharingV2DecompressionSessionFactory.make(format: format, callback: nil)
    else { return false }

    defer { VTDecompressionSessionInvalidate(session) }
    guard let sample = try? sample(keyframe, format: format) else { return false }

    let outcome = Outcome()
    let expected = ScreenSharingV2DecompressionSessionFactory.decodedPixelFormat(format)
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      status, _, image, _, _ in
      outcome.decoded = status == noErr && image.map(CVPixelBufferGetPixelFormatType) == expected
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    return status == noErr && outcome.decoded
  }

  private static func sample(_ bytes: [UInt8], format: CMVideoFormatDescription) throws -> CMSampleBuffer {
    let block = try bytes.withUnsafeBytes { try ScreenSharingV2Decoder.block(copying: $0) }
    var sample: CMSampleBuffer?
    var size = bytes.count
    let status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
      sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw ScreenSharingError.codec("Create decode sample", status) }

    return sample
  }

  static let parameterSets: [[UInt8]] = [
    [
      0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xbe, 0x08, 0x00, 0x00, 0x03, 0x00,
      0x00, 0x1e, 0x15, 0xc0, 0x90,
    ],
    [
      0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xbe, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1e, 0x90,
      0x02, 0x84, 0x08, 0x38, 0x18, 0x7c, 0x40, 0xaf, 0x72, 0x2c, 0xa8, 0x80,
    ],
    [0x44, 0x01, 0xc0, 0x2c, 0xbc, 0x14, 0xc9],
  ]

  static let keyframe: [UInt8] = [
    0x00, 0x00, 0x00, 0x24, 0x28, 0x01, 0xaf, 0x10, 0x8b, 0x58, 0xea, 0x95, 0xdc, 0x7f, 0xff, 0x98, 0x49, 0xaf,
    0xfe, 0x0e, 0x31, 0x3f, 0xed, 0xd9, 0xec, 0x94, 0x2e, 0xb8, 0x31, 0x09, 0x25, 0xc0, 0x91, 0x30, 0x2b, 0x47,
    0x82, 0xef, 0x93, 0xe2,
  ]
}
