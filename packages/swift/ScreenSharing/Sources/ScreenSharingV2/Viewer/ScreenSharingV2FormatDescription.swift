import CoreMedia
import Foundation
import ScreenSharing

enum ScreenSharingV2FormatDescription {
  static func make(parameterSets: [Data]) throws -> CMVideoFormatDescription {
    var description: CMFormatDescription?
    let retained = parameterSets.map { $0 as NSData }
    let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = retained.map(\.length)
    let status = withExtendedLifetime(retained) {
      CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count, parameterSetPointers: pointers,
        parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw ScreenSharingError.codec("Read HEVC format", status) }

    return description
  }
}
