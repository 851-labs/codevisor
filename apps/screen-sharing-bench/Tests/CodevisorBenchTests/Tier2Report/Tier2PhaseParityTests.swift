import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2PhaseParityTests {
  @Test func aMissOfM3BelowTwelveMillisecondsIsFlaggedAsARegression() throws {
    let parity = Tier2PhaseParity(results: Self.results(phaseMs: 9.8, v2ScrollP50: 45))

    #expect(parity.regressions.map(\.group.scene) == ["scroll"])
    let headline = try #require(parity.headline)
    #expect(headline.contains("Regression (851-4092)"))
    #expect(headline.contains("codevisor-v2 on scroll (p50 +15.0, p95 +5.0 ms against Apple HP)"))
  }

  @Test func theSameMissAtOrAboveTwelveMillisecondsIsNoRegression() {
    let parity = Tier2PhaseParity(results: Self.results(phaseMs: 13.6, v2ScrollP50: 45))

    #expect(parity.regressions.isEmpty)
    #expect(parity.status == "not checked (at or above 12 ms)")
  }

  @Test func v2WithinM3BelowTwelveMillisecondsIsReportedAsMet() {
    let parity = Tier2PhaseParity(results: Self.results(phaseMs: 9.8, v2ScrollP50: 36))

    #expect(parity.regressions.isEmpty)
    #expect(parity.status == "✅ within M3")
  }

  private static func results(phaseMs: Double, v2ScrollP50: Double) -> [BenchResult] {
    [(BenchSystem.appleHP, [30.0, 45]), (.codevisorV2, [v2ScrollP50, 50])].flatMap { system, ages in
      (1...2).map { repetition in
        var result = BenchResult(
          system: system, scene: "scroll", resolution: "R1x2", network: "N0", repetition: repetition, seed: 1)
        result.imageAgeMs = BenchDistribution(ages)
        result.displayPhaseMs = phaseMs
        return result
      }
    }
  }
}
