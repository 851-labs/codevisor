import ScreenSharingBench
import Testing

struct BenchLongGapsTests {
  @Test func gapsAreCountedAndTimedAboveEachFixedThresholdWhateverTheStreamsPace() {
    let slow = BenchLongGaps(gapsMs: [300, 300, 600, 250, 500, 6_000])

    #expect(slow.over250Ms == BenchLongGaps.Tally(count: 5, totalMs: 7_700))
    #expect(slow.over500Ms == BenchLongGaps.Tally(count: 2, totalMs: 6_600))
  }

  @Test func aStreamThatStuttersEvenlyStillShowsItsLongGaps() {
    let stuttering = Array(repeating: 400.0, count: 60)

    #expect(BenchFreezes(gapsMs: stuttering, activeDurationMs: 24_000).count == 0)
    #expect(BenchLongGaps(gapsMs: stuttering).over250Ms == BenchLongGaps.Tally(count: 60, totalMs: 24_000))
  }
}
