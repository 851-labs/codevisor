import Testing
@testable import ScreenSharing

struct ScreenSharingCaptureArrivalsTests {
  @Test func anArrivalIsTakenOnceSoARefreshedFrameCarriesNoStaleHostStages() {
    let arrivals = ScreenSharingCaptureArrivals()
    arrivals.record(sourceTimestampNs: 10, arrivedNs: 12)
    arrivals.record(sourceTimestampNs: 20, arrivedNs: 25)

    #expect(arrivals.take(sourceTimestampNs: 20) == 25)
    #expect(arrivals.take(sourceTimestampNs: 20) == nil)
    #expect(arrivals.take(sourceTimestampNs: 10) == 12)
  }

  @Test func theOldestArrivalIsForgottenOnceTheRingIsFull() {
    let arrivals = ScreenSharingCaptureArrivals()
    for index in 0..<17 { arrivals.record(sourceTimestampNs: Int64(index), arrivedNs: Int64(index) + 100) }

    #expect(arrivals.take(sourceTimestampNs: 0) == nil)
    #expect(arrivals.take(sourceTimestampNs: 1) == 101)
  }
}
