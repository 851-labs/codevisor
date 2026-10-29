import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingHostTimingMarkerTests {
  private let timing = ScreenSharingHostFrameTiming(
    clock: 0xfedc_ba98_7654_3210, captureUs: 4_321, hostQueueUs: 0, encodeUs: 12_345_678)

  @Test(arguments: ScreenSharingVideoCodec.allCases)
  func timingRoundTripsWithoutStartCodeEmulation(codec: ScreenSharingVideoCodec) {
    let unit = marker(timing, codec: codec)
    #expect(!unit.contains(0))
    #expect(ScreenSharingHostTimingMarker.timing(in: [unit], codec: codec) == timing)
  }

  @Test func olderViewersStripTheTimingUnitAndKeepReadingTheIdentity() {
    let identity = ScreenSharingSourceMarker.nalUnit(timestampNs: 42, codec: .hevc)
    let unit = marker(timing, codec: .hevc)
    #expect(ScreenSharingSourceMarker.isMarker(unit, codec: .hevc))
    #expect(ScreenSharingSourceMarker.timestampNs(in: [unit, identity], codec: .hevc) == 42)
    #expect(ScreenSharingHostTimingMarker.timing(in: [identity], codec: .hevc) == nil)
  }

  @Test func durationsOutsideTheWireRangeAreClamped() {
    let extreme = ScreenSharingHostFrameTiming(clock: .max, captureUs: -5, hostQueueUs: .max, encodeUs: 1)
    let decoded = ScreenSharingHostTimingMarker.timing(in: [marker(extreme, codec: .h264)], codec: .h264)
    #expect(decoded?.clock == .max)
    #expect(decoded?.captureUs == 0)
    #expect(decoded?.hostQueueUs == ScreenSharingHostFrameTiming.maximumDurationUs)
  }

  @Test func aCorruptedUnitIsIgnored() {
    var unit = marker(timing, codec: .h264)
    unit[unit.count - 3] &= 0x7f
    #expect(ScreenSharingHostTimingMarker.timing(in: [unit], codec: .h264) == nil)
    #expect(ScreenSharingHostTimingMarker.timing(in: [unit.dropLast()], codec: .h264) == nil)
  }

  @Test func hostStagesAreMeasuredBetweenConsecutiveTimestamps() {
    let measured = ScreenSharingHostFrameTiming(
      sourceNs: 1_000_000, capturedNs: 3_500_000, submittedNs: 4_000_000, encodedNs: 9_000_000, clock: 9)
    #expect(measured == ScreenSharingHostFrameTiming(clock: 9, captureUs: 2_500, hostQueueUs: 500, encodeUs: 5_000))
  }

  private func marker(_ timing: ScreenSharingHostFrameTiming, codec: ScreenSharingVideoCodec) -> Data {
    var data = Data()
    ScreenSharingHostTimingMarker.append(timing, codec: codec, to: &data)
    return data
  }
}
