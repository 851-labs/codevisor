import CoreMedia
import Foundation
import ScreenSharing
import VideoToolbox

struct ScreenSharingEncodedSample {
  static let lengthSize = 4

  let isKeyFrame: Bool
  let ltrToken: UInt64?
  let accessUnit: ScreenSharingAccessUnit

  init(_ sample: CMSampleBuffer) throws {
    guard let block = sample.dataBuffer, let format = sample.formatDescription else {
      throw ScreenSharingError.invalid("The encoded frame has no data.")
    }

    let attachments = Self.attachments(of: sample)
    isKeyFrame = attachments?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    ltrToken = (attachments?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.uint64Value
    if isKeyFrame {
      accessUnit = ScreenSharingAccessUnit(try Self.parameterSets(of: format) + Self.copy(block))
    } else {
      accessUnit = ScreenSharingAccessUnit(contiguous: try Self.contiguous(block))
    }
  }

  private static func attachments(of sample: CMSampleBuffer) -> [CFString: Any]? {
    let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    return array?.first
  }

  private static func parameterSets(of format: CMFormatDescription) throws -> Data {
    var count = 0
    var headerLength: Int32 = 0
    try check(
      CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength), "Read HEVC parameter sets")
    guard Int(headerLength) == lengthSize else { throw ScreenSharingError.invalid("Unexpected NAL length size.") }

    return try (0..<count).reduce(into: Data()) { data, index in data += try parameterSet(format, index: index) }
  }

  private static func parameterSet(_ format: CMFormatDescription, index: Int) throws -> Data {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    try check(
      CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "Read HEVC parameter set")
    guard let pointer else { throw ScreenSharingError.invalid("Missing HEVC parameter set.") }

    var length = UInt32(size).bigEndian
    return Data(bytes: &length, count: lengthSize) + Data(bytes: pointer, count: size)
  }

  private static func copy(_ block: CMBlockBuffer) throws -> Data {
    var data = Data(count: CMBlockBufferGetDataLength(block))
    let status = data.withUnsafeMutableBytes { raw in
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
    }
    try check(status, "Read encoded frame")
    return data
  }

  private static func contiguous(_ block: CMBlockBuffer) throws -> CMBlockBuffer {
    guard !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) else { return block }

    var contiguous: CMBlockBuffer?
    try check(
      CMBlockBufferCreateContiguous(
        allocator: kCFAllocatorDefault, sourceBuffer: block, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguous),
      "Make the encoded frame contiguous")
    guard let contiguous else { throw ScreenSharingError.invalid("The encoded frame has no data.") }

    return contiguous
  }

  private static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ScreenSharingError.codec(operation, status) }
  }
}
