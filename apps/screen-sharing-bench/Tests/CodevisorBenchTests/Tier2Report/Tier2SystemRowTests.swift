import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2SystemRowTests {
  @Test func theTargetRowShowsTheMedianGapsOverTheFixedThresholdsAndTheTimeInThem() throws {
    let results = [[300.0, 600], [300, 300, 300, 1_000], [700]].enumerated().map { index, gaps in
      var result = BenchResult(
        system: .codevisorV2VCP, scene: "scroll", resolution: "R1", network: "N7", repetition: index + 1, seed: 1)
      result.longGaps = BenchLongGaps(gapsMs: gaps)
      return result
    }
    let group = Tier2Group(scene: "scroll", resolution: "R1", network: "N7")

    let row = try #require(Tier2SystemRow(group: group, system: .codevisorV2VCP, results: results, encoded: nil))

    #expect(row.text.contains("| – | 2.0 | 0.9 | 1.0 | 0.7 | – |"))
  }
}
