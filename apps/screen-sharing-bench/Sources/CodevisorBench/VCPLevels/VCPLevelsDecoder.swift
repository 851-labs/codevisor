import CoreMedia
import Foundation
import ScreenSharingBench
import ScreenSharingV2

struct VCPLevelsDecoder {
  struct Decoded {
    let image: CVPixelBuffer
    let format: CMVideoFormatDescription
  }

  private struct AccessUnit {
    let parameterSets: [Data]
    let slices: Data
  }

  private static let lengthSize = 4
  private static let parameterSetTypes: ClosedRange<UInt8> = 32...34

  static func decode(_ units: [ScreenSharingAccessUnit], to pixelFormat: OSType) throws -> Decoded {
    var decoder: EncodeLabDecoder?
    var format: CMVideoFormatDescription?
    var last: CVPixelBuffer?
    for unit in units {
      let split = try unit.withUnsafeBytes(Self.split)
      if !split.parameterSets.isEmpty {
        let description = try formatDescription(split.parameterSets)
        decoder = try EncodeLabDecoder(format: description, output: pixelFormat)
        format = description
      }
      guard let decoder, let format else {
        throw BenchUsageError(message: "the first access unit has no parameter sets")
      }

      last = try decoder.decode(try sample(split.slices, format: format))
    }
    guard let last, let format else { throw BenchUsageError(message: "nothing decoded") }

    return Decoded(image: last, format: format)
  }

  private static func split(_ bytes: UnsafeRawBufferPointer) throws -> AccessUnit {
    var parameterSets: [Data] = []
    var offset = 0
    while offset + lengthSize < bytes.count {
      let length = bytes[offset..<offset + lengthSize].reduce(0) { $0 << 8 | Int($1) }
      let start = offset + lengthSize
      guard length > 0, start + length <= bytes.count else { throw BenchUsageError(message: "malformed NAL unit") }
      guard parameterSetTypes.contains(bytes[start] >> 1 & 0x3f) else { break }

      parameterSets.append(Data(bytes[start..<start + length]))
      offset = start + length
    }
    guard offset < bytes.count else { throw BenchUsageError(message: "an access unit has no slices") }

    return AccessUnit(parameterSets: parameterSets, slices: Data(bytes[offset...]))
  }

  private static func formatDescription(_ parameterSets: [Data]) throws -> CMVideoFormatDescription {
    let retained = parameterSets.map { $0 as NSData }
    let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    var description: CMFormatDescription?
    let status = withExtendedLifetime(retained) {
      CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: retained.count, parameterSetPointers: pointers,
        parameterSetSizes: retained.map(\.length), nalUnitHeaderLength: Int32(lengthSize), extensions: nil,
        formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw BenchUsageError(message: "HEVC format (\(status))") }

    return description
  }

  private static func sample(_ slices: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var sample: CMSampleBuffer?
    var size = slices.count
    let copied = slices.withUnsafeBytes { bytes in
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr
        && block.map {
          CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!, blockBuffer: $0, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        } == true
    }
    guard copied, let block,
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { throw BenchUsageError(message: "decode sample") }

    return sample
  }
}
