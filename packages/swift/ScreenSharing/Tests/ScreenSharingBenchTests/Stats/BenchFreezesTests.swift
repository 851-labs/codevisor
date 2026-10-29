import ScreenSharingBench
import Testing

struct BenchFreezesTests {
  @Test func theFirstThirtyGapsWarmTheAverageUpAndCannotFreeze() {
    let warmingUp = Array(repeating: 16.0, count: 29) + [1_000]
    let warm = Array(repeating: 16.0, count: 30) + [1_000]

    #expect(BenchFreezes(gapsMs: warmingUp, activeDurationMs: 60_000).count == 0)
    #expect(BenchFreezes(gapsMs: warm, activeDurationMs: 60_000).count == 1)
  }

  @Test(arguments: [
    (averageMs: 20.0, thresholdMs: 170.0),
    (averageMs: 100.0, thresholdMs: 300.0),
  ])
  func aGapFreezesFromTheLargerOfThreeAveragesAndAveragePlus150(averageMs: Double, thresholdMs: Double) {
    let history = Array(repeating: averageMs, count: 30)

    #expect(BenchFreezes(gapsMs: history + [thresholdMs - 0.01], activeDurationMs: 1_000).count == 0)
    #expect(BenchFreezes(gapsMs: history + [thresholdMs], activeDurationMs: 1_000).count == 1)
  }

  @Test func theAverageSlidesOverThePreviousThirtyGaps() {
    let gaps = Array(repeating: 100.0, count: 30) + Array(repeating: 20.0, count: 30) + [200]

    #expect(BenchFreezes(gapsMs: gaps, activeDurationMs: 1_000).count == 1)
  }

  @Test func gapsLongerThanFiveSecondsArePausesNotFreezes() {
    let gaps = Array(repeating: 16.0, count: 30) + [5_001, 16, 5_000]

    let freezes = BenchFreezes(gapsMs: gaps, activeDurationMs: 60_000)

    #expect(freezes.count == 1 && freezes.totalMs == 5_000)
    #expect(freezes.pauses == 1 && freezes.pausesTotalMs == 5_001)
  }

  @Test func freezeTimeIsReportedAgainstActiveSceneTime() {
    let onGlassNs = (0...30).map { Int64($0) * 20_000_000 } + [800_000_000, 820_000_000, 1_220_000_000]
    let gaps = BenchFrameGaps.intervalsMs(between: onGlassNs)

    let freezes = BenchFreezes(gapsMs: gaps, activeDurationMs: 30_000)

    #expect(gaps.count == onGlassNs.count - 1 && gaps.first == 20)
    #expect(freezes.count == 2 && freezes.totalMs == 600)
    #expect(freezes.ratio == 0.02 && freezes.perMinute == 4)
  }
}
