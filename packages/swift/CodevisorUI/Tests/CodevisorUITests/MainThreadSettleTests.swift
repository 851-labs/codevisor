import Testing
@testable import CodevisorUI

struct MainThreadSettleTests {
  private let millisecond: UInt64 = 1_000_000

  @Test(
    "Busy time adds up the awake stretches, and the switch ends when the thread first stays asleep for the quiet interval"
  )
  func settlesAfterQuietSleep() {
    var settle = MainThreadSettle(start: 0, quietNanoseconds: 100 * millisecond, limitNanoseconds: 2_000 * millisecond)

    settle.willSleep(at: 40 * millisecond)
    #expect(settle.didWake(at: 45 * millisecond) == nil)
    settle.willSleep(at: 60 * millisecond)
    let result = settle.didWake(at: 160 * millisecond)

    #expect(
      result
        == MainThreadSettle.Result(
          busyNanoseconds: 55 * millisecond, firstPassNanoseconds: 40 * millisecond,
          settleNanoseconds: 60 * millisecond, settled: true))
  }

  @Test("A thread that never stays quiet is reported as unsettled once the limit passes")
  func reportsUnsettledAtLimit() {
    var settle = MainThreadSettle(start: 0, quietNanoseconds: 100 * millisecond, limitNanoseconds: 200 * millisecond)

    settle.willSleep(at: 150 * millisecond)
    let result = settle.didWake(at: 210 * millisecond)

    #expect(
      result
        == MainThreadSettle.Result(
          busyNanoseconds: 150 * millisecond, firstPassNanoseconds: 150 * millisecond,
          settleNanoseconds: 210 * millisecond, settled: false))
  }
}
