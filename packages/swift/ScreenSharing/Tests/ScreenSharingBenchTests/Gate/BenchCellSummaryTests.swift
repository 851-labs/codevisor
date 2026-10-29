import ScreenSharingBench
import Testing

struct BenchCellSummaryTests {
  @Test func eachCellTakesTheMedianOfItsRepetitionsInFirstSeenOrder() throws {
    let results = [
      Self.result("scroll", "N0", repetition: 1, e2eMs: [60, 70], network: 50),
      Self.result("video", "N0", repetition: 1, e2eMs: [80, 90], network: 60),
      Self.result("scroll", "N0", repetition: 2, e2eMs: [50, 64], network: 40),
      Self.result("video", "N0", repetition: 2, e2eMs: [82, 96], network: 62),
      Self.result("scroll", "N0", repetition: 3, e2eMs: [58, 80], network: 48),
    ]

    let summaries = BenchCellSummary.summaries(results)

    #expect(summaries.map(\.cell.scene) == ["scroll", "video"])
    let scroll = try #require(summaries.first)
    #expect(scroll.repetitions == 3 && scroll.valid == 3 && scroll.errors == 0)
    #expect(scroll.e2eP50Ms == 58 && scroll.e2eP95Ms == 70)
    #expect(scroll.e2eP50MinMs == 50 && scroll.e2eP50MaxMs == 60)
    #expect(scroll.stagesP50Ms.network == 48)
    #expect(summaries.last?.e2eP50Ms == 81, "an even count takes the mean of the middle two")
  }

  @Test func invalidRepetitionsCountAsErrorsAndStayOutOfTheMedians() {
    var failed = Self.result("typing", "N3", repetition: 2, e2eMs: [500, 900], network: 480)
    failed.valid = false
    failed.invalidReason = "the codec failed: -12903"
    var decodeErrors = Self.result("typing", "N3", repetition: 3, e2eMs: [30, 40], network: 10)
    decodeErrors.codecErrors = 2
    let results = [Self.result("typing", "N3", repetition: 1, e2eMs: [26, 30], network: 12), failed, decodeErrors]

    let summary = BenchCellSummary.summaries(results)[0]

    #expect(summary.repetitions == 3 && summary.valid == 2 && summary.errors == 3)
    #expect(summary.e2eP50Ms == 28)
  }

  @Test(arguments: [("N0", nil, 12), ("N3", 0.04, nil)] as [(String, Double?, Double?)])
  func gateSamplesJudgeFreezesOnLossAndTheJitterBufferSplitOnACleanLink(
    network: String, gatedRatio: Double?, outsideP50Ms: Double?
  ) {
    var result = Self.result("scroll", network, repetition: 1, e2eMs: [27, 91], network: 15)
    result.freezes = BenchFreezes(count: 3, totalMs: 280, ratio: 0.04, perMinute: 26, pauses: 0, pausesTotalMs: 0)
    result.e2eOutsideJitterBufferMs = BenchDistribution([12, 20])

    let sample = BenchGateSample(BenchCellSummary.summaries([result])[0])

    #expect(sample.freezeRatio == gatedRatio)
    #expect(sample.e2eOutsideJitterBufferP50Ms == outsideP50Ms)
    #expect(sample.e2eP50Ms == 27 && sample.updatesPerS == 60)
  }

  private static func result(
    _ scene: String, _ network: String, repetition: Int, e2eMs: [Double], network networkMs: Double
  ) -> BenchResult {
    var result = BenchResult(
      system: .codevisor, scene: scene, resolution: "R1", network: network, repetition: repetition, seed: 7)
    result.e2eMs = BenchDistribution(e2eMs)
    result.updatesPerS = 60
    var stages = BenchStageTimings()
    stages.networkResidual = BenchDistribution([networkMs])
    result.stagesMs = stages
    return result
  }
}
