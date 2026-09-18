import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingSourceMarkerTests {
  private let sps = Data([0x67, 0x42, 0xe0, 0x34])
  private let pps = Data([0x68, 0xce, 0x3c, 0x80])
  private let slice = Data([0x65, 0x88, 0x84, 0x00, 0x00, 0x03, 0x01])

  @Test func markerRoundTripsForEachCodecWithoutStartCodeEmulation() {
    for codec in ScreenSharingVideoCodec.allCases {
      for value: Int64 in [0, 1, 127, 128, 1_726_100_000_123_456_789, Int64.max] {
        let unit = ScreenSharingSourceMarker.nalUnit(timestampNs: value, codec: codec)
        #expect(!unit.contains(0))
        #expect(unit.count == (codec == .h264 ? 30 : 31))
        let type = codec == .h264 ? Int(unit[0] & 0x1f) : Int((unit[0] >> 1) & 0x3f)
        #expect(type == (codec == .h264 ? 6 : 39))
        // Neither decoder filter (slices, parameter sets) may select the marker.
        #expect(!(codec == .h264 ? 1...5 : 0...31).contains(type) && ![7, 8, 32, 33, 34].contains(type))
        #expect(codec == .h264 || (unit[0] & 0x80 == 0 && unit[1] & 7 != 0))
        #expect(ScreenSharingSourceMarker.isMarker(unit, codec: codec))
        #expect(ScreenSharingSourceMarker.timestampNs(in: [sps, pps, unit, slice], codec: codec) == value)
      }
    }
  }

  @Test func markerSurvivesAnnexBFramingAndIsStrippedFromDecoderInput() throws {
    let marker = ScreenSharingSourceMarker.nalUnit(timestampNs: 42, codec: .h264)
    var frame = Data()
    for unit in [sps, pps, marker, slice] {
      frame.append(contentsOf: [0, 0, 0, 1])
      frame.append(unit)
    }
    let units = try NALUnitBitstream.nalUnits(frame)
    #expect(units.count == 4)
    #expect(ScreenSharingSourceMarker.timestampNs(in: units, codec: .h264) == 42)
    let converted = try NALUnitBitstream.annexB(NALUnitBitstream.lengthPrefixed(units))
    #expect(ScreenSharingSourceMarker.timestampNs(in: try NALUnitBitstream.nalUnits(converted), codec: .h264) == 42)
    let forVideoToolbox = units.filter { !ScreenSharingSourceMarker.isMarker($0, codec: .h264) }
    #expect(forVideoToolbox == [sps, pps, slice])
  }

  @Test func absentForeignOrMalformedMarkersAreIgnoredButOwnMalformedMarkersAreStillStripped() {
    let marker = ScreenSharingSourceMarker.nalUnit(timestampNs: 99, codec: .h264)
    var foreignIdentifier = marker
    foreignIdentifier[5] ^= 0x01
    var corruptValue = marker
    corruptValue[marker.count - 2] &= 0x7f
    var nonCanonicalLeadingBits = marker
    nonCanonicalLeadingBits[marker.count - 11] = 0x81
    var wrongTrailer = marker
    wrongTrailer[marker.count - 1] = 0x00
    let encoderVersionSei = Data([0x06, 0x05] + [0x10] + Array(repeating: UInt8(0xaa), count: 16) + [0x80])
    let hevcMarker = ScreenSharingSourceMarker.nalUnit(timestampNs: 99, codec: .hevc)
    for units: [Data] in [
      [], [sps, pps, slice], [encoderVersionSei], [foreignIdentifier], [corruptValue], [nonCanonicalLeadingBits],
      [wrongTrailer], [marker.dropLast()], [marker + Data([0x80])], [hevcMarker],
    ] {
      #expect(ScreenSharingSourceMarker.timestampNs(in: units, codec: .h264) == nil)
    }
    #expect(ScreenSharingSourceMarker.timestampNs(in: [marker], codec: .hevc) == nil)
    #expect(ScreenSharingSourceMarker.timestampNs(in: [corruptValue, marker], codec: .h264) == 99)
    for own in [corruptValue, nonCanonicalLeadingBits, wrongTrailer, marker.dropLast(), marker + Data([0x80])] {
      #expect(ScreenSharingSourceMarker.isMarker(own, codec: .h264))
    }
    for foreign in [encoderVersionSei, foreignIdentifier, hevcMarker, sps, slice, Data()] {
      #expect(!ScreenSharingSourceMarker.isMarker(foreign, codec: .h264))
    }
  }

  @Test func identityTravelsWithTheBufferIndependentlyOfTranslatedTimestamps() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    #expect(ScreenSharingFrameIdentity.sourceTimestampNs(of: buffer) == nil)
    // Non-microsecond capture time; WebRTC would truncate and translate it.
    ScreenSharingFrameIdentity.attach(sourceTimestampNs: 1_726_100_000_123_456_789, to: buffer)
    let translated = ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 1_726_100_000_130_000_000)
    #expect(ScreenSharingFrameIdentity.sourceTimestampNs(of: translated.pixelBuffer) == 1_726_100_000_123_456_789)
    // A recycled buffer receives the new capture's identity.
    ScreenSharingFrameIdentity.attach(sourceTimestampNs: 7, to: buffer)
    #expect(ScreenSharingFrameIdentity.sourceTimestampNs(of: buffer) == 7)
  }

  @Test func transportEncoderRefusesInputWithoutIdentityThroughTheEncoderFailureLifecycle() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let metrics = ScreenSharingMetrics()
    #expect(ScreenSharingFrameIdentity.required(of: buffer, metrics: metrics) == nil)
    let failed = metrics.snapshot()
    #expect(failed.counters["encoderInputWithoutIdentity"] == 1)
    #expect(failed.labels["encoderError"] == "Encoder input carries no content identity.")
    let healthy = ScreenSharingMetrics()
    ScreenSharingFrameIdentity.attach(sourceTimestampNs: 42, to: buffer)
    #expect(ScreenSharingFrameIdentity.required(of: buffer, metrics: healthy) == 42)
    #expect(
      healthy.snapshot().counters["encoderInputWithoutIdentity"] == nil
        && healthy.snapshot().labels["encoderError"] == nil)
  }
}
