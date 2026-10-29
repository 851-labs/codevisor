import ScreenSharingBench
import Testing

struct BenchSystemComparisonTests {
  struct Case: Sendable {
    let appleHp: [Double]
    let codevisor: [Double]
    let better: BenchSystemComparison.Better
    let noiseBand: Double
    let verdict: BenchComparison.Verdict
  }

  @Test(arguments: [
    Case(appleHp: [100, 104, 102], codevisor: [80, 83, 81], better: .lower, noiseBand: 4, verdict: .codevisorFaster),
    Case(appleHp: [100, 104, 102], codevisor: [99, 101, 103], better: .lower, noiseBand: 4, verdict: .noDifference),
    Case(appleHp: [50, 51, 50], codevisor: [70, 71, 72], better: .lower, noiseBand: 2, verdict: .appleFaster),
    Case(appleHp: [30, 31, 30], codevisor: [59, 60, 60], better: .higher, noiseBand: 1, verdict: .codevisorFaster),
  ])
  func aDifferenceCountsOnlyBeyondTheWiderRepetitionSpread(_ example: Case) throws {
    let outcome = try #require(
      BenchSystemComparison.verdict(appleHp: example.appleHp, codevisor: example.codevisor, better: example.better))

    #expect(outcome.noiseBand == example.noiseBand)
    #expect(outcome.verdict == example.verdict)
  }
}
