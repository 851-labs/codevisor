import Testing

@testable import CodevisorBench

struct EncodeLabScheduleTests {
  @Test func stepsOncePerVersionAndRefreshesOnceAtTheFirstChangeFromTheRefreshTick() {
    var schedule = EncodeLabSchedule(timeline: .everyTicks(15), ticks: 60, refreshTick: 20)
    var steps: [EncodeLabSchedule.Step] = []
    while let step = schedule.next() { steps.append(step) }

    #expect(steps.map(\.tick) == [0, 15, 30, 45])
    #expect(steps.map(\.version) == [0, 1, 2, 3])
    #expect(steps.map(\.refreshes) == [false, false, true, false])
    #expect(steps.allSatisfy { !$0.repeats })
  }

  @Test func repeatsAnUnchangedVersionEveryOtherTickUntilTheNextChange() {
    var schedule = EncodeLabSchedule(timeline: .everyTicks(15), ticks: 20, refreshTick: 60, refinements: 3)
    var steps: [EncodeLabSchedule.Step] = []
    while let step = schedule.next() { steps.append(step) }

    #expect(steps.map(\.tick) == [0, 2, 4, 6, 15, 17, 19])
    #expect(steps.map(\.repeats) == [false, true, true, true, false, true, true])
  }
}
