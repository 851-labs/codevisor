import ScreenSharingBench
import Testing

struct BenchInputScheduleTests {
  @Test func aScheduleHoldsEachKindItsCountOfTimesSpacedWithinTheRange() {
    let schedule = BenchInputSchedule(keys: 200, clicks: 150, seed: 7)

    #expect(schedule.steps.count { $0.kind == .key } == 200)
    #expect(schedule.steps.count { $0.kind == .click } == 150)
    #expect(
      schedule.steps.allSatisfy {
        (BenchInputSchedule.shortestWaitMs...BenchInputSchedule.longestWaitMs).contains($0.waitMs)
      })
  }
}
