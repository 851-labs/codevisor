import Foundation
import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2SystemsTests {
  @Test(arguments: [
    (#""system": "codevisor-v2""#, BenchSystem.codevisorV2),
    (#""system": "codevisor-v2-vcp""#, BenchSystem.codevisorV2VCP),
    (#""system": "apple-hp""#, BenchSystem.appleHP),
    (#""system": "codevisor""#, BenchSystem.codevisor),
    (#""system": "codevisor", "engine": "v2""#, BenchSystem.codevisorV2),
  ])
  func aRunCountsAsTheSystemItsMetaNamesOrItsOlderEngineRan(fields: String, system: BenchSystem) throws {
    let json =
      #"{"index": 1, "scene": "scroll", "repetition": 1, "seed": 1, "duration_s": 60, "#
      + #""host_observer": true, "git_sha": "f00", "started_at": "2026-10-31T10:00:00Z", "# + fields + "}"
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let meta = try decoder.decode(Tier2RunMeta.self, from: Data(json.utf8))

    #expect(meta.benchSystem == system)
  }

  @Test func eachCodevisorSystemIsComparedWithAppleHPOnItsOwnRepetitions() {
    let results =
      [
        (BenchSystem.appleHP, [50.0, 51, 52]), (.codevisor, [80, 82, 81]), (.codevisorV2, [40, 41, 39]),
        (.codevisorV2VCP, [51, 50, 52]),
      ]
      .flatMap { system, ages in ages.enumerated().map { Self.result(system, repetition: $0 + 1, imageAgeP50: $1) } }

    let comparisons = Tier2Comparisons.make(results).filter { $0.metric == "image_age_ms.p50" }

    #expect(comparisons.map(\.system) == [.codevisor, .codevisorV2, .codevisorV2VCP])
    #expect(comparisons.map(\.codevisor) == [[80, 82, 81], [40, 41, 39], [51, 50, 52]])
    #expect(comparisons.map(\.verdict) == [.appleFaster, .codevisorFaster, .noDifference])
  }

  @Test func cpuGapsUnderOnePercentagePointAreNoDifference() throws {
    let results = [(BenchSystem.appleHP, [0.3, 0.3, 0.3]), (.codevisorV2, [0.9, 0.9, 0.9])].flatMap { system, cpu in
      cpu.enumerated().map { index, cpu in
        var result = Self.result(system, repetition: index + 1, imageAgeP50: 30)
        result.cpuPct = BenchResult.PerMachine(host: BenchResult.ProcessUsage(p50: cpu, p95: cpu))
        return result
      }
    }

    let comparison = try #require(Tier2Comparisons.make(results).first { $0.metric == "cpu_pct.host.p50" })

    #expect(comparison.verdict == .noDifference)
    #expect(Tier2Comparisons.basis(of: comparison) == "gap under the minimum effect")
  }

  static func result(_ system: BenchSystem, repetition: Int, imageAgeP50: Double) -> BenchResult {
    var result = BenchResult(
      system: system, scene: "scroll", resolution: "R1x2", network: "N0", repetition: repetition, seed: 1)
    result.imageAgeMs = BenchDistribution([imageAgeP50])
    return result
  }
}
