import CoreMedia
import Foundation
import ScreenSharingBench
import ScreenSharingV2
import VideoToolbox

struct VCPLevelsDecoder {
  struct Decoded {
    let image: CVPixelBuffer
    let format: CMVideoFormatDescription
  }

  private static let parameterSetTypes: ClosedRange<UInt8> = 32...34

  static func decode(_ units: [ScreenSharingAccessUnit], to pixelFormat: OSType) throws -> Decoded {
    var session: VTDecompressionSession?
    var format: CMVideoFormatDescription?
    var last: CVPixelBuffer?
    defer { if let session { VTDecompressionSessionInvalidate(session) } }
    for unit in units {
      let (parameterSets, slices) = unit.withUnsafeBytes(split)
      if !parameterSets.isEmpty {
        let description = try formatDescription(parameterSets)
        if let session { VTDecompressionSessionInvalidate(session) }
        session = try makeSession(description, pixelFormat: pixelFormat)
        format = description
      }
      guard let session, let format else {
        throw BenchUsageError(message: "the first access unit has no parameter sets")
      }

      last = try decode(slices, format: format, session: session) ?? last
    }
    guard let last, let format else { throw BenchUsageError(message: "nothing decoded") }

    return Decoded(image: last, format: format)
  }

  private static func split(_ bytes: UnsafeRawBufferPointer) -> ([Data], Data) {
    var parameterSets: [Data] = []
    var offset = 0
    while offset + 4 < bytes.count {
      let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      let unit = bytes[(offset + 4)..<min(bytes.count, offset + 4 + length)]
      guard parameterSetTypes.contains((unit.first ?? 0) >> 1 & 0x3f) else { break }

      parameterSets.append(Data(unit))
      offset += 4 + length
    }
    return (parameterSets, Data(bytes[offset...]))
  }

  private static func formatDescription(_ parameterSets: [Data]) throws -> CMVideoFormatDescription {
    let retained = parameterSets.map { $0 as NSData }
    let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    var description: CMFormatDescription?
    let status = withExtendedLifetime(retained) {
      CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: retained.count, parameterSetPointers: pointers,
        parameterSetSizes: retained.map(\.length), nalUnitHeaderLength: 4, extensions: nil,
        formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw BenchUsageError(message: "HEVC format (\(status))") }

    return description
  }

  private static func makeSession(
    _ format: CMVideoFormatDescription, pixelFormat: OSType
  ) throws -> VTDecompressionSession {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: format, decoderSpecification: specification,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
    guard status == noErr, let session else { throw BenchUsageError(message: "decoder (\(status))") }

    return session
  }

  private static func decode(
    _ slices: Data, format: CMVideoFormatDescription, session: VTDecompressionSession
  ) throws -> CVPixelBuffer? {
    var block: CMBlockBuffer?
    var sample: CMSampleBuffer?
    var size = slices.count
    let copied = slices.withUnsafeBytes { bytes in
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr
        && CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
    }
    guard copied, let block,
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { throw BenchUsageError(message: "decode sample") }

    nonisolated(unsafe) var image: CVPixelBuffer?
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      _, _, decoded, _, _ in image = decoded
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    guard status == noErr else { throw BenchUsageError(message: "decode (\(status))") }

    return image
  }
}
