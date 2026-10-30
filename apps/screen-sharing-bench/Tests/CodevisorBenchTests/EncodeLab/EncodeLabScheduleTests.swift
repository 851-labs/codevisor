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
  }
}
