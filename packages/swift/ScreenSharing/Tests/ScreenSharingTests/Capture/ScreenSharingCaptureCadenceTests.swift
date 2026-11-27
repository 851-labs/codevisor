import CoreMedia
import Testing

@testable import ScreenSharing

struct ScreenSharingCaptureCadenceTests {
  private static func intervalNs(_ cadence: ScreenSharingCaptureCadence) -> Int64 {
    cadence.minimumFrameInterval.convertScale(1_000_000_000, method: .default).value
  }

  @Test(arguments: [60.0, 59.94, 60.4, 60.6, 50, 30])
  func aDisplayOfAtMostSixtyHertzIsCapturedAtEveryRefresh(refreshHz: Double) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

    #expect(cadence.minimumFrameInterval == CMTime(value: 1, timescale: 480))
  }

  @Test func aOneHundredTwentyHertzDisplayIsCapturedAtEveryOtherRefreshWithHeadroom() {
    #expect(Self.intervalNs(ScreenSharingCaptureCadence(displayRefreshHz: 120)) == 15_625_000)
  }

  @Test(arguments: [(90.0, 20_833_333 as Int64), (144, 19_531_250), (75, 25_000_000)])
  func aFasterDisplayNeverYieldsMoreThanSixtyCapturesASecond(refreshHz: Double, intervalNs: Int64) {
    #expect(Self.intervalNs(ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)) == intervalNs)
  }

  @Test(arguments: [(120.01, 120.0), (119.99, 120), (240.01, 240), (180.3, 180)])
  func aRefreshRateJustOffAMultipleOfSixtyIsCapturedAsThatMultiple(refreshHz: Double, nominalHz: Double) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)
    let nominal = ScreenSharingCaptureCadence(displayRefreshHz: nominalHz)

    #expect(abs(Self.intervalNs(cadence) - Self.intervalNs(nominal)) < 100_000)
  }

  @Test(arguments: [nil, 0.0, -1, .nan])
  func anUnknownRefreshRateIsTreatedAsAOneHundredTwentyHertzDisplay(refreshHz: Double?) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

    #expect(cadence == ScreenSharingCaptureCadence(displayRefreshHz: 120))
  }

  @Test func cadencesAreEqualWhenTheyAskForTheSameInterval() {
    #expect(ScreenSharingCaptureCadence(displayRefreshHz: 60) == ScreenSharingCaptureCadence(displayRefreshHz: 59.94))
    #expect(ScreenSharingCaptureCadence(displayRefreshHz: 60) != ScreenSharingCaptureCadence(displayRefreshHz: 120))
  }

  @Test func aVideoRateBelowSixtyIsKeptOnAnyDisplay() {
    for refreshHz in [60.0, 120] {
      let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

      #expect(cadence.minimumFrameInterval(requesting: 15) == CMTime(value: 1, timescale: 15))
      #expect(cadence.minimumFrameInterval(requesting: 60) == cadence.minimumFrameInterval)
    }
  }
}
