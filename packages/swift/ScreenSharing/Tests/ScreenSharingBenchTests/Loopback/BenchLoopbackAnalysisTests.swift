import ScreenSharingBench
import Testing

struct BenchLoopbackAnalysisTests {
  private static let ms: Int64 = 1_000_000
  private static let cadence = BenchSceneCadence(changeIntervalMs: 100, changesContinuously: false)
  private static let produced = (0..<10).map { BenchVersionEvent(version: $0, ns: Int64($0) * 100 * ms) }
  private static let window = (200 * ms)..<(1_000 * ms)

  @Test func onlyVersionsProducedAfterTheWarmUpAndShownCount() throws {
    let frames = Self.produced.filter { $0.version != 5 }.map { Self.frame(sourceNs: $0.ns) }
    let analysis = BenchLoopbackAnalysis(
      produced: Self.produced, frames: frames, windowNs: Self.window, cadence: Self.cadence, endpoint: .committed)
    var result = Self.result

    analysis.apply(to: &result)

    #expect(result.e2eMs == BenchDistribution(Array(repeating: 21, count: 7)))
    #expect(result.e2eEndpoint == .committed)
    #expect(result.updatesPerS == 7 / 0.8)
    #expect(result.shownRatio == 7.0 / 8)
    #expect(result.skippedVersions == 1)
    #expect(result.gapMs == BenchDistribution([100, 100, 200, 100, 100, 100]))
    #expect(result.judderMs == 100)
    #expect(result.freezes == nil, "a scene that idles between changes has no freezes")
  }

  @Test func framesTheSourceNeverProducedAreNotLatencySamples() {
    let refresh = Self.frame(sourceNs: 450 * Self.ms, latencyMs: 500)
    let frames = [Self.frame(sourceNs: 400 * Self.ms), refresh]
    let analysis = BenchLoopbackAnalysis(
      produced: Self.produced, frames: frames, windowNs: Self.window, cadence: Self.cadence, endpoint: .committed)

    #expect(analysis.frames == [Self.frame(sourceNs: 400 * Self.ms)])
  }

  @Test func eachStageIsTheSpanBetweenItsTimestampsOnOneClock() throws {
    let analysis = BenchLoopbackAnalysis(
      produced: Self.produced, frames: [Self.frame(sourceNs: 300 * Self.ms)], windowNs: Self.window,
      cadence: Self.cadence, endpoint: .committed)
    var result = Self.result

    analysis.apply(to: &result)

    let stages = try #require(result.stagesMs)
    let p50s = [
      stages.capture, stages.captureQueue, stages.encode, stages.networkResidual, stages.decode, stages.renderQueue,
    ].map { $0?.p50 }
    #expect(p50s == [1, 2, 5, 3, 4, 6])
    #expect(stages.present == nil)
  }

  @Test func onGlassLatencyUsesOnlyFramesThatReachedTheGlass() {
    var shown = Self.frame(sourceNs: 300 * Self.ms)
    shown.onGlassNs = shown.renderCommitNs + 9 * Self.ms
    let frames = [shown, Self.frame(sourceNs: 400 * Self.ms)]
    let analysis = BenchLoopbackAnalysis(
      produced: Self.produced, frames: frames, windowNs: Self.window, cadence: Self.cadence, endpoint: .onGlass)
    var result = Self.result

    analysis.apply(to: &result)

    #expect(result.e2eMs == BenchDistribution([30]))
    #expect(result.stagesMs?.present == BenchDistribution([9]))
  }

  @Test func continuouslyChangingScenesCountFreezes() {
    let continuous = BenchSceneCadence(changeIntervalMs: 100, changesContinuously: true)
    let analysis = BenchLoopbackAnalysis(
      produced: Self.produced, frames: Self.produced.map { Self.frame(sourceNs: $0.ns) }, windowNs: Self.window,
      cadence: continuous, endpoint: .committed)
    var result = Self.result

    analysis.apply(to: &result)

    #expect(result.freezes == BenchFreezes(gapsMs: Array(repeating: 100, count: 7), activeDurationMs: 800))
  }

  private static var result: BenchResult {
    BenchResult(system: .codevisor, scene: "typing", resolution: "R1", network: "N0", repetition: 1, seed: 7)
  }

  private static func frame(sourceNs: Int64, latencyMs: Int64 = 21) -> BenchFrameTimestamps {
    let decodeInputNs = sourceNs + 11 * ms
    return BenchFrameTimestamps(
      sourceNs: sourceNs, captureCallbackNs: sourceNs + ms, encodeSubmitNs: sourceNs + 3 * ms,
      encodeOutputNs: sourceNs + 8 * ms, decodeInputNs: decodeInputNs, decodeOutputNs: decodeInputNs + 4 * ms,
      renderCommitNs: sourceNs + latencyMs * ms)
  }
}
