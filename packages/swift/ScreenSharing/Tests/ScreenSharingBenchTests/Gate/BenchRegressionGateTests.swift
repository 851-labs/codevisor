import ScreenSharingBench
import Testing

struct BenchRegressionGateTests {
  private static let baseline = [10.0, 11, 9, 10, 10.5, 9.5, 10].map {
    BenchGateSample(e2eP50Ms: $0, e2eP95Ms: 20, updatesPerS: 60, freezeRatio: 0.01, psnrY: 40)
  }

  @Test(arguments: [
    (metric: "e2e_p50_ms", within: sample(e2eP50Ms: 13), beyond: sample(e2eP50Ms: 13.01)),
    (metric: "e2e_p95_ms", within: sample(e2eP95Ms: 25), beyond: sample(e2eP95Ms: 25.01)),
    (metric: "updates_per_s", within: sample(updatesPerS: 57), beyond: sample(updatesPerS: 56.99)),
    (metric: "freeze_ratio", within: sample(freezeRatio: 0.0299), beyond: sample(freezeRatio: 0.0301)),
    (metric: "psnr_y", within: sample(psnrY: 39.5), beyond: sample(psnrY: 39.49)),
  ])
  func eachMetricFailsOnlyBeyondItsThreshold(metric: String, within: BenchGateSample, beyond: BenchGateSample) {
    #expect(BenchRegressionGate.regressions(baseline: Self.baseline, first: within, second: within).isEmpty)
    #expect(
      BenchRegressionGate.regressions(baseline: Self.baseline, first: beyond, second: beyond).map(\.metric) == [metric])
  }

  @Test func latencyThresholdsScaleWithTheBaselineMedian() {
    let slowBaseline = Self.baseline.map {
      BenchGateSample(e2eP50Ms: $0.e2eP50Ms.map { $0 * 10 }, e2eP95Ms: 200, updatesPerS: 60)
    }
    let within = BenchGateSample(e2eP50Ms: 115, e2eP95Ms: 240, updatesPerS: 60)
    let beyond = BenchGateSample(e2eP50Ms: 115.01, e2eP95Ms: 240, updatesPerS: 60)

    #expect(BenchRegressionGate.regressions(baseline: slowBaseline, first: within, second: within).isEmpty)
    #expect(
      BenchRegressionGate.regressions(baseline: slowBaseline, first: beyond, second: beyond).map(\.metric) == [
        "e2e_p50_ms"
      ])
  }

  @Test func oneRegressedRunOutOfTwoIsNotARegression() {
    let regressed = Self.sample(e2eP50Ms: 30)

    #expect(BenchRegressionGate.regressions(baseline: Self.baseline, first: regressed, second: Self.sample()).isEmpty)
    #expect(BenchRegressionGate.regressions(baseline: Self.baseline, first: regressed, second: regressed).count == 1)
  }

  @Test func onlyTheLastSevenBaselineRunsCount() throws {
    let stale = Array(repeating: Self.sample(e2eP50Ms: 100), count: 10)
    let run = Self.sample(e2eP50Ms: 30)

    let regressions = BenchRegressionGate.regressions(baseline: stale + Self.baseline, first: run, second: run)

    #expect(regressions.count == 1)
    let regression = try #require(regressions.first)
    #expect(regression.metric == "e2e_p50_ms" && regression.baseline == 10 && regression.observed == [30, 30])
  }

  @Test func aJitterBufferSwitchingStateFailsNothingOnceTheStageIsSplit() {
    let baseline = Array(repeating: Self.split(e2eP50Ms: 55, outsideMs: 20, jitterBufferMs: 35), count: 7)
    let capped = Self.split(e2eP50Ms: 88, outsideMs: 20, jitterBufferMs: 68)
    let slowerPipeline = Self.split(e2eP50Ms: 88, outsideMs: 23.01, jitterBufferMs: 65)
    let largerBuffer = Self.split(e2eP50Ms: 100, outsideMs: 20, jitterBufferMs: 75.01)

    #expect(BenchRegressionGate.regressions(baseline: baseline, first: capped, second: capped).isEmpty)
    #expect(
      BenchRegressionGate.regressions(baseline: baseline, first: slowerPipeline, second: slowerPipeline).map(\.metric)
        == ["e2e_outside_jitter_buffer_p50_ms"])
    #expect(
      BenchRegressionGate.regressions(baseline: baseline, first: largerBuffer, second: largerBuffer).map(\.metric) == [
        "jitter_buffer_p50_ms"
      ])
  }

  @Test func aBaselineWithoutTheSplitIsJudgedOnWholeE2e() {
    let capped = Self.split(e2eP50Ms: 88, outsideMs: 20, jitterBufferMs: 68)

    let regressions = BenchRegressionGate.regressions(baseline: Self.baseline, first: capped, second: capped)

    #expect(regressions.map(\.metric) == ["e2e_p50_ms", "e2e_p95_ms"])
  }

  @Test func errorsInBothRunsFailWithoutABaseline() {
    let failing = BenchGateSample(e2eP50Ms: 10, e2eP95Ms: 20, updatesPerS: 60, errors: 2)

    #expect(BenchRegressionGate.regressions(baseline: [], first: failing, second: failing).map(\.metric) == ["errors"])
  }

  private static func split(e2eP50Ms: Double, outsideMs: Double, jitterBufferMs: Double) -> BenchGateSample {
    var sample = BenchGateSample(e2eP50Ms: e2eP50Ms, e2eP95Ms: e2eP50Ms + 5, updatesPerS: 60)
    sample.e2eOutsideJitterBufferP50Ms = outsideMs
    sample.e2eOutsideJitterBufferP95Ms = outsideMs + 5
    sample.jitterBufferP50Ms = jitterBufferMs
    return sample
  }

  private static func sample(
    e2eP50Ms: Double = 10, e2eP95Ms: Double = 20, updatesPerS: Double = 60, freezeRatio: Double = 0.01,
    psnrY: Double = 40
  ) -> BenchGateSample {
    BenchGateSample(
      e2eP50Ms: e2eP50Ms, e2eP95Ms: e2eP95Ms, updatesPerS: updatesPerS, freezeRatio: freezeRatio, psnrY: psnrY)
  }
}
