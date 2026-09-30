import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingHEVCFormatTests {
  private func configuration(profile: UInt8 = 4, chroma: UInt8 = 3, luma: UInt8 = 0, color: UInt8 = 0) -> Data {
    var bytes = [UInt8](repeating: 0, count: 23)
    bytes[0] = 1
    bytes[1] = 0x20 | profile
    bytes[16] = 0xfc | chroma
    bytes[17] = 0xf8 | luma
    bytes[18] = 0xf8 | color
    return Data(bytes)
  }

  @Test func validatesExplicitEightBitChromaWithoutInferringFromProfile() throws {
    let full = try ScreenSharingHEVCFormat(configuration: configuration())
    try full.validate(for: .hevc444)
    #expect(full.profile == 4 && full.chroma == 3 && full.lumaDepth == 8 && full.chromaDepth == 8)
    let main = try ScreenSharingHEVCFormat(configuration: configuration(profile: 1, chroma: 1))
    try main.validate(for: .hevc)
    #expect(throws: (any Error).self) { try main.validate(for: .hevc444) }
    #expect(throws: (any Error).self) { try full.validate(for: .hevc) }
    #expect(throws: (any Error).self) { try full.validate(for: .h264) }
  }

  /// HDR (851-2380): 10-bit Main 4:4:4 is still profile 4, and 10-bit 4:2:0 is Main10 (2).
  @Test func tenBitStreamsAreHighDynamicRangeOfTheSameCodec() throws {
    let full = try ScreenSharingHEVCFormat(configuration: configuration(luma: 2, color: 2))
    try full.validate(for: .hevc444)
    #expect(full.codec == .hevc444 && full.dynamicRange == .high)
    let main10 = try ScreenSharingHEVCFormat(configuration: configuration(profile: 2, chroma: 1, luma: 2, color: 2))
    #expect(main10.codec == .hevc && main10.dynamicRange == .high)
    // Main (1) is 8-bit only, and luma and chroma must agree.
    #expect(
      try ScreenSharingHEVCFormat(configuration: configuration(profile: 1, chroma: 1, luma: 2, color: 2)).codec == nil)
    #expect(try ScreenSharingHEVCFormat(configuration: configuration(luma: 2)).dynamicRange == nil)
    #expect(try ScreenSharingHEVCFormat(configuration: configuration(luma: 4, color: 4)).codec == nil)
  }

  @Test func rejectsSilentChromaAndDepthFallback() throws {
    for bytes in [
      configuration(chroma: 1), configuration(chroma: 2), configuration(profile: 1),
      configuration(luma: 2), configuration(color: 2),
    ] {
      let actual = try ScreenSharingHEVCFormat(configuration: bytes)
      #expect(throws: (any Error).self) { try actual.validate(for: .hevc444) }
    }
  }

  @Test func rejectsTruncationAndUnknownConfigurationVersion() {
    for length in 0..<23 {
      #expect(throws: (any Error).self) {
        try ScreenSharingHEVCFormat(configuration: configuration().prefix(length))
      }
    }
    var unknown = configuration()
    unknown[0] = 2
    #expect(throws: (any Error).self) { try ScreenSharingHEVCFormat(configuration: unknown) }
  }

  @Test func rejectsMalformedHEVCHeadersBeforeCreatingHardwareDecoder() {
    let decoder = ScreenSharingDecoder(metrics: ScreenSharingMetrics(), codec: .hevc444) { _ in
      Issue.record("Malformed NAL must not produce a decoded frame.")
    }
    for header: [UInt8] in [[0x40], [0xc0, 1], [0x40, 0]] {
      let frame = ScreenSharingEncodedFrame(
        data: Data([0, 0, 0, 1] + header), timestampNs: 0,
        rtpTimestamp: 0, width: 64, height: 64, isKeyFrame: true)
      #expect(throws: (any Error).self) { try decoder.decode(frame) }
    }
  }

  @Test func preservesHEVCParameterAndSliceNALsAcrossFramingConversion() throws {
    let units = [Data([0x40, 1, 0xaa]), Data([0x42, 1, 0xbb]), Data([0x44, 1, 0xcc]), Data([0x26, 1, 0xdd])]
    let bytes = try NALUnitBitstream.annexB(NALUnitBitstream.lengthPrefixed(units))
    #expect(try NALUnitBitstream.nalUnits(bytes) == units)
  }
}
