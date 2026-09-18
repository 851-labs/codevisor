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

  @Test func threeAndFourByteStartCodesDelimitTheSameUnits() throws {
    let units = [Data([0x67, 0x42, 0xe0, 0x34]), Data([0x68, 0xce, 0x3c, 0x80]), Data([0x65, 0x88, 0x84])]
    for startCode: [UInt8] in [[0, 0, 1], [0, 0, 0, 1]] {
      var frame = Data()
      for unit in units {
        frame.append(contentsOf: startCode)
        frame.append(unit)
      }
      #expect(try NALUnitBitstream.nalUnits(frame) == units)
    }
  }

  @Test func aMultiNALAccessUnitKeepsEveryUnitAndItsOrder() throws {
    // Delimiter, parameter sets, SEI and two slices in one access unit: the
    // decoder's type filters depend on the order and on nothing being merged.
    let units = [
      Data([0x09, 0x30]), Data([0x67, 0x42, 0xe0, 0x34]), Data([0x68, 0xce, 0x3c, 0x80]),
      Data([0x06, 0x05, 0x02, 0xaa, 0xbb, 0x80]), Data([0x65, 0x88, 0x84]), Data([0x65, 0x88, 0x99]),
    ]
    var frame = Data()
    for unit in units {
      frame.append(contentsOf: [0, 0, 0, 1])
      frame.append(unit)
    }
    #expect(try NALUnitBitstream.nalUnits(frame) == units)
    #expect(try NALUnitBitstream.nalUnits(NALUnitBitstream.annexB(NALUnitBitstream.lengthPrefixed(units))) == units)
  }

  @Test func rejectsZeroLengthUnitsWhereverTheyAppear() {
    // Back-to-back start codes of either width, and a trailing start code with
    // nothing behind it: an empty unit is a framing bug, never a silent skip.
    for bytes: [UInt8] in [
      [0, 0, 0, 1], [0, 0, 0, 1, 0, 0, 0, 1, 0x65], [0, 0, 1, 0, 0, 1, 0x65], [0, 0, 0, 1, 0x65, 0, 0, 1],
    ] {
      #expect(throws: (any Error).self) { try NALUnitBitstream.nalUnits(Data(bytes)) }
    }
    #expect(throws: (any Error).self) { try NALUnitBitstream.lengthPrefixed([Data([0x65]), Data()]) }
    #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data([0, 0, 0, 0, 0x65])) }
  }

  @Test func lengthPrefixedFramesRoundTripAtEveryPrefixWidth() throws {
    // VideoToolbox reports the width its format description uses; 1...4 are the
    // only legal ones, and every one of them must produce the same units.
    let units = [Data([0x67, 0x42]), Data([0x65, 0xaa, 0xbb])]
    for lengthSize in 1...4 {
      var prefixed = Data()
      for unit in units {
        for shift in (0..<lengthSize).reversed() { prefixed.append(UInt8((unit.count >> (8 * shift)) & 0xff)) }
        prefixed.append(unit)
      }
      #expect(try NALUnitBitstream.nalUnits(NALUnitBitstream.annexB(prefixed, lengthSize: lengthSize)) == units)
    }
    for lengthSize in [-1, 0, 5, 8] {
      #expect(throws: (any Error).self) {
        try NALUnitBitstream.annexB(Data([0, 0, 0, 1, 0x65]), lengthSize: lengthSize)
      }
    }
  }

  @Test func rejectsLengthPrefixesThatOverrunTheirFrame() {
    // A declared length past the end, on the first unit and on a later one,
    // then a prefix too short to hold its own width.
    for bytes: [UInt8] in [[0, 0, 0, 3, 0x65, 0xaa], [0, 0, 0, 1, 0x65, 0, 0, 0, 2, 0x65], [0, 0]] {
      #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data(bytes)) }
    }
    #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data([0, 2, 0x65]), lengthSize: 2) }
    #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(Data([0, 0, 0x65]), lengthSize: 2) }
  }

  @Test func emulationPreventionBytesNeverSplitAUnit() throws {
    // 00 00 03 xx is the escaped form of payload that would otherwise read as a
    // start code. It must survive both framings byte for byte.
    let slice = Data([0x65, 0x88, 0, 0, 3, 0, 0, 0, 3, 1, 0, 0, 3, 2, 0xff])
    #expect(try NALUnitBitstream.nalUnits(Data([0, 0, 0, 1]) + slice) == [slice])
    #expect(try NALUnitBitstream.nalUnits(NALUnitBitstream.annexB(NALUnitBitstream.lengthPrefixed([slice]))) == [slice])
  }

  @Test func rejectsFramesAndUnitsBeyondTheBoundedMaximum() {
    let oversized = Data(repeating: 0, count: NALUnitBitstream.maximumFrameBytes + 1)
    #expect(throws: (any Error).self) { try NALUnitBitstream.nalUnits(oversized) }
    #expect(throws: (any Error).self) { try NALUnitBitstream.annexB(oversized) }
    // The length prefix itself has to fit inside the same budget.
    let atTheLimit = Data(repeating: 0x65, count: NALUnitBitstream.maximumFrameBytes)
    #expect(throws: (any Error).self) { try NALUnitBitstream.lengthPrefixed([atTheLimit]) }
  }

  @Test func rejectsInvalidConfigurationOnDecode() {
    let invalid = Data(#"{"width":1921,"height":1080,"framesPerSecond":60,"bitrate":12000000}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ScreenSharingVideoConfiguration.self, from: invalid) }
  }
}
