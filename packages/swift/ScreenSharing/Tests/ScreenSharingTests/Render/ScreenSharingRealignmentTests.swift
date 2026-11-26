import Testing

@testable import ScreenSharing

struct ScreenSharingRealignmentTests {
  private static let periodNs: Int64 = 16_666_667
  private static let leadNs: Int64 = 3_000_000
  private static let starvedWaitNs: Int64 = 14_700_000

  private static func refresh(_ index: Int64) -> Int64 { 1_000_000_000 + index * periodNs }

  private static func arrival(_ index: Int64) -> Int64 { refresh(index) - leadNs }

  private static func atFullRate(through last: Int64) -> ScreenSharingRealignment {
    var realignment = ScreenSharingRealignment()
    for index in 0...last { realignment.arrived(atNs: arrival(index)) }
    return realignment
  }

  @Test func skipsTheArrivalAfterAStarvedCommitAndDrawsTheOneAfter() {
    var realignment = Self.atFullRate(through: 4)
    let starvedAt = Self.refresh(4) + 1_300_000

    let starved = realignment.committed(waitedNs: Self.starvedWaitNs, atNs: starvedAt)
    let rightAfter = realignment.holds(atNs: starvedAt + 1_500_000)
    realignment.arrived(atNs: Self.arrival(5))
    let nextArrival = realignment.holds(atNs: Self.arrival(5))
    realignment.arrived(atNs: Self.arrival(6))
    let arrivalAfter = realignment.holds(atNs: Self.arrival(6))

    #expect(starved)
    #expect(rightAfter != nil)
    #expect(nextArrival != nil)
    #expect(arrivalAfter == nil)
  }

  @Test func realignsAtMostOnceASecond() {
    var realignment = Self.atFullRate(through: 4)
    _ = realignment.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(4) + 1_300_000)
    realignment.arrived(atNs: Self.arrival(5))
    realignment.arrived(atNs: Self.arrival(6))
    _ = realignment.holds(atNs: Self.arrival(6))
    for index in Int64(7)...10 { realignment.arrived(atNs: Self.arrival(index)) }

    let soonAfter = realignment.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(10) + 1_300_000)
    let heldSoonAfter = realignment.holds(atNs: Self.arrival(11))
    for index in Int64(11)...80 { realignment.arrived(atNs: Self.arrival(index)) }
    let aSecondLater = realignment.committed(waitedNs: Self.starvedWaitNs, atNs: Self.refresh(80) + 1_300_000)

    #expect(!soonAfter)
    #expect(heldSoonAfter == nil)
    #expect(aSecondLater)
  }

  @Test func leavesSparseStreamsAlone() {
    var realignment = ScreenSharingRealignment()
    for index in Int64(0)...8 { realignment.arrived(atNs: Self.refresh(index * 6)) }

    let starved = realignment.committed(waitedNs: 11_800_000, atNs: Self.refresh(48) + 12_000_000)
    let held = realignment.holds(atNs: Self.refresh(49))

    #expect(!starved)
    #expect(held == nil)
  }

  @Test func leavesAnUnstarvedCommitAlone() {
    var realignment = Self.atFullRate(through: 6)

    let starved = realignment.committed(waitedNs: 300_000, atNs: Self.refresh(6) - 2_700_000)
    let held = realignment.holds(atNs: Self.arrival(7))

    #expect(!starved)
    #expect(held == nil)
  }
}
