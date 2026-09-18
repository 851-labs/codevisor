import Foundation
import Testing
@testable import ScreenSharing

struct NALUnitBitstreamTests {
  @Test func mixedStartCodesRoundTrip() throws {
    let frame = Data([0, 0, 0, 1, 0x67, 0xaa, 0, 0, 1, 0x68, 0xbb, 0, 0, 0, 1, 0x65, 0xcc])
    let units = try NALUnitBitstream.nalUnits(frame)
    #expect(units == [Data([0x67, 0xaa]), Data([0x68, 0xbb]), Data([0x65, 0xcc])])
    let converted = try NALUnitBitstream.annexB(NALUnitBitstream.lengthPrefixed(units))
    #expect(try NALUnitBitstream.nalUnits(converted) == units)
  }

  @Test func rejectsTruncatedAndEmptyUnits() {
    for bytes: [UInt8] in [[0, 0, 0, 5, 0x65], [0, 0, 0, 0], [0, 0, 1]] {
      #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data(bytes)) }
    }
    #expect(throws: (any Error).self) { try NALUnitBitstream.nalUnits(Data([0, 0, 1])) }
    #expect(throws: (any Error).self) { try NALUnitBitstream.nalUnits(Data([0x65, 0xaa])) }
  }

  @Test func rejectsExcessiveNALCountAndEmptyFrame() {
    let manyUnits = Data(Array(repeating: [UInt8(0), 0, 1, 0x65], count: 1025).flatMap { $0 })
    #expect(throws: (any Error).self) { try NALUnitBitstream.nalUnits(manyUnits) }
    #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data()) }
  }

  @Test func acceptsEmulationPreventionBytes() throws {
    let nal = Data([0x65, 0, 0, 3, 1, 0xaa])
    #expect(try NALUnitBitstream.nalUnits(Data([0, 0, 0, 1]) + nal) == [nal])
  }

  @Test func rejectsInvalidConfigurationOnDecode() {
    let invalid = Data(#"{"width":1921,"height":1080,"framesPerSecond":60,"bitrate":12000000}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ScreenSharingVideoConfiguration.self, from: invalid) }
  }
}
