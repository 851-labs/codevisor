import CoreMedia
import Testing

@testable import ScreenSharing

struct ScreenSharingCaptureCadenceTests {
  private static func intervalNs(_ cadence: ScreenSharingCaptureCadence) -> Int64 {
    cadence.minimumFrameInterval.convertScale(1_000_000_000, method: .default).value
  }

  @Test(arguments: [60.0, 59.94, 50, 30])
  func aDisplayOfAtMostSixtyHertzIsCapturedAtEveryRefresh(refreshHz: Double) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

    #expect(cadence.minimumFrameInterval == CMTime(value: 1, timescale: 480))
    #expect(cadence.framesPerSecond == refreshHz)
  }

  @Test func aOneHundredTwentyHertzDisplayIsCapturedAtEveryOtherRefreshWithHeadroom() {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: 120)

    #expect(Self.intervalNs(cadence) == 15_625_000)
    #expect(cadence.framesPerSecond == 60)
  }

  @Test(arguments: [(90.0, 20_833_333 as Int64, 45.0), (144, 19_531_250, 48), (75, 25_000_000, 37.5)])
  func aFasterDisplayNeverYieldsMoreThanSixtyCapturesASecond(refreshHz: Double, intervalNs: Int64, perSecond: Double) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

    #expect(Self.intervalNs(cadence) == intervalNs)
    #expect(cadence.framesPerSecond == perSecond)
  }

  @Test(arguments: [nil, 0.0, -1, .nan])
  func anUnknownRefreshRateIsTreatedAsAOneHundredTwentyHertzDisplay(refreshHz: Double?) {
    let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

    #expect(cadence == ScreenSharingCaptureCadence(displayRefreshHz: 120))
  }

  @Test func aVideoRateBelowSixtyIsKeptOnAnyDisplay() {
    for refreshHz in [60.0, 120] {
      let cadence = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)

      #expect(cadence.minimumFrameInterval(requesting: 15) == CMTime(value: 1, timescale: 15))
      #expect(cadence.minimumFrameInterval(requesting: 60) == cadence.minimumFrameInterval)
    }
  }
}
