import ScreenSharingBench
import Testing

struct BenchDistributionTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let samples: [Double]
    let p50: Double
    let p95: Double
    let max: Double

    var testDescription: String { "\(samples.count) samples" }
  }

  @Test(arguments: [
    Case(samples: [7], p50: 7, p95: 7, max: 7),
    Case(samples: [4, 1, 3, 2], p50: 2, p95: 4, max: 4),
    Case(samples: (1...20).map(Double.init).reversed(), p50: 10, p95: 19, max: 20),
    Case(samples: (1...100).map(Double.init), p50: 50, p95: 95, max: 100),
    Case(samples: (1...101).map(Double.init), p50: 51, p95: 96, max: 101),
  ])
  func percentilesUseNearestRankOnSortedSamples(_ example: Case) throws {
    let distribution = try #require(BenchDistribution(example.samples))

    #expect(distribution.count == example.samples.count)
    #expect([distribution.p50, distribution.p95, distribution.max] == [example.p50, example.p95, example.max])
  }

  @Test func noSamplesHaveNoDistribution() {
    #expect(BenchDistribution([]) == nil)
  }
}
