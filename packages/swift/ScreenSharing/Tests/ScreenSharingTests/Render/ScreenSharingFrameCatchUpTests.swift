import Testing

@testable import ScreenSharing

struct ScreenSharingFrameCatchUpTests {
  private static let periodNs: Int64 = 16_666_667
  private static let leadNs: Int64 = 3_000_000
  private static let starvedWaitNs: Int64 = 14_700_000

  private static func refresh(_ index: Int64) -> Int64 { 1_000_000_000 + index * periodNs }

  private static func arrival(_ index: Int64) -> Int64 { refresh(index) - leadNs }

  private static func atFullRate(through last: Int64) -> ScreenSharingFrameCatchUp {
    var catchUp = ScreenSharingFrameCatchUp()
    for index in 0...last { catchUp.arrived(atNs: arrival(index)) }
    return catchUp
  }

  @Test func holdsTheArrivalAfterAStarvedCommitAndReleasesTheOneAfter() {
    var catchUp = Self.atFullRate(through: 4)
    let starvedAt = Self.refresh(4) + 1_300_000

    let starved = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: starvedAt)
    catchUp.arrived(atNs: Self.arrival(5))
    let nextArrival = catchUp.holds(atNs: Self.arrival(5))
    catchUp.arrived(atNs: Self.arrival(6))
    let arrivalAfter = catchUp.holds(atNs: Self.arrival(6))

    #expect(starved)
    #expect(nextArrival.map { $0 > 0 && $0 <= 2 * Self.periodNs + 4_000_000 } == true)
    #expect(arrivalAfter == nil)
  }

  @Test func catchesUpAtMostOnceASecond() {
    var catchUp = Self.atFullRate(through: 4)
    _ = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(4) + 1_300_000)
    for index in Int64(5)...10 { catchUp.arrived(atNs: Self.arrival(index)) }
    _ = catchUp.holds(atNs: Self.arrival(10))

    let soonAfter = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(10) + 1_300_000)
    for index in Int64(11)...80 { catchUp.arrived(atNs: Self.arrival(index)) }
    let aSecondLater = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(80) + 1_300_000)

    #expect(!soonAfter)
    #expect(aSecondLater)
  }

  @Test(arguments: [2, 4, 6])
  func neverHoldsAStreamSlowerThanTheDisplay(refreshesPerFrame: Int64) {
    var catchUp = ScreenSharingFrameCatchUp()
    for index in Int64(0)...8 { catchUp.arrived(atNs: Self.arrival(index * refreshesPerFrame)) }

    let starved = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(8 * refreshesPerFrame) + 1_300_000)

    #expect(!starved)
    #expect(catchUp.holds(atNs: Self.arrival(8 * refreshesPerFrame + 1)) == nil)
  }

  @Test func neverHoldsAfterACommitThatGotItsDrawableAtOnce() {
    var catchUp = Self.atFullRate(through: 6)

    let starved = catchUp.committed(waitedNs: 300_000, atNs: Self.refresh(6) - 2_700_000)

    #expect(!starved)
    #expect(catchUp.holds(atNs: Self.arrival(7)) == nil)
  }

  @Test func followsTheDisplaysRefreshPeriod() {
    var catchUp = ScreenSharingFrameCatchUp()
    catchUp.periodNs = 8_333_333
    for index in Int64(0)...4 { catchUp.arrived(atNs: index * Self.periodNs) }

    let starved = catchUp.committed(waitedNs: Self.starvedWaitNs, atNs: 4 * Self.periodNs + 1_000_000)

    #expect(!starved)
  }
}
