import ScreenSharingBench
import Testing

struct BenchSystemComparisonTests {
  struct Case: Sendable {
    let appleHp: [Double]
    let codevisor: [Double]
    let better: BenchSystemComparison.Better
    let noiseBand: Double
    let verdict: BenchComparison.Verdict
    let basis: BenchSystemComparison.Basis?
  }

  @Test(arguments: [
    Case(
      appleHp: [100, 104, 102], codevisor: [80, 83, 81], better: .lower, noiseBand: 4, verdict: .codevisorFaster,
      basis: .noiseBand),
    Case(
      appleHp: [100, 104, 102], codevisor: [99, 101, 103], better: .lower, noiseBand: 4, verdict: .noDifference,
      basis: nil),
    Case(
      appleHp: [50, 51, 50], codevisor: [70, 71, 72], better: .lower, noiseBand: 2, verdict: .appleFaster,
      basis: .noiseBand),
    Case(
      appleHp: [30, 31, 30], codevisor: [59, 60, 60], better: .higher, noiseBand: 1, verdict: .codevisorFaster,
      basis: .noiseBand),
    Case(
      appleHp: [23.9, 23.9, 23.9], codevisor: [324, 957, 341], better: .lower, noiseBand: 633, verdict: .appleFaster,
      basis: .noOverlap),
    Case(
      appleHp: [100, 130, 110], codevisor: [125, 140, 135], better: .lower, noiseBand: 30, verdict: .noDifference,
      basis: nil),
    Case(
      appleHp: [10, 30, 12], codevisor: [31, 33, 60], better: .lower, noiseBand: 29, verdict: .noDifference, basis: nil),
    Case(appleHp: [61], codevisor: [40, 60, 49], better: .lower, noiseBand: 20, verdict: .noDifference, basis: nil),
    Case(
      appleHp: [15.06, 15.06, 15.06], codevisor: [15.08, 15.08, 15.08], better: .higher, noiseBand: 0,
      verdict: .noDifference, basis: .belowMinimumEffect),
    Case(
      appleHp: [100, 100.5, 100], codevisor: [101.5, 101.5, 101.5], better: .lower, noiseBand: 0.5,
      verdict: .noDifference, basis: .belowMinimumEffect),
  ])
  func aDifferenceNeedsAGapBeyondTheNoiseBandOrRepetitionsClearlyApartAndAtLeastTheMinimumEffect(_ example: Case) throws
  {
    let outcome = try #require(
      BenchSystemComparison.verdict(appleHp: example.appleHp, codevisor: example.codevisor, better: example.better))

    #expect(outcome.noiseBand == example.noiseBand)
    #expect(outcome.verdict == example.verdict)
    #expect(outcome.basis == example.basis)
  }
}
