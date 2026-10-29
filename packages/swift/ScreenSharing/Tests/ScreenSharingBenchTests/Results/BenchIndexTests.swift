import Foundation
import ScreenSharingBench
import Testing

struct BenchIndexTests {
  private static let method = BenchMethod(durationS: 30, warmUpS: 10, repetitions: 3, plan: "gate")
  private static let scroll = BenchCell(system: .codevisor, scene: "scroll", resolution: "R1", network: "N0")

  @Test func theBaselineComesOnlyFromNightliesOfTheSameTierMethodAndPlan() throws {
    let core = BenchMethod(durationS: 30, warmUpS: 10, repetitions: 3, plan: "core")
    let shorter = BenchMethod(durationS: 12, warmUpS: 5, repetitions: 1, plan: "gate")
    let entries = [
      Self.entry("gha-1-1", trigger: "nightly", e2eP50Ms: 60),
      Self.entry("gha-2-1", trigger: "adhoc", e2eP50Ms: 90),
      Self.entry("gha-3-1", trigger: "nightly", e2eP50Ms: 62, method: core),
      Self.entry("gha-3-2", trigger: "nightly", e2eP50Ms: 63, method: shorter),
      Self.entry("gha-4-1", trigger: "nightly", e2eP50Ms: 61, tier: 2),
      Self.entry("gha-5-1", trigger: "nightly", e2eP50Ms: 64),
    ]
    let gateRun = BenchRun(
      id: "gha-6-1-first", tier: 1, startedAt: .distantPast, gitSha: "f00", trigger: "pull_request",
      method: Self.method)

    let nightlies = BenchIndex.nightlies(like: gateRun, in: entries)

    #expect(nightlies.map(\.run.id) == ["gha-1-1", "gha-5-1"])
    #expect(BenchIndex.baseline(for: Self.scroll, in: nightlies).map(\.e2eP50Ms) == [60, 64])
  }

  @Test func anIndexLineIsOneSnakeCasedJSONObjectThatReadsBack() throws {
    let entry = Self.entry("gha-1-1", trigger: "nightly", e2eP50Ms: 60)

    let line = try BenchIndex.line(entry)

    let text = String(decoding: line, as: UTF8.self)
    #expect(text.hasSuffix("}\n") && text.dropLast().contains("\n") == false)
    #expect(text.contains(#""e2e_p50_ms":60"#) && text.contains(#""warm_up_s":10"#))
    #expect(try BenchIndex.entries(line + line) == [entry, entry])
  }

  private static func entry(
    _ id: String, trigger: String, e2eP50Ms: Double, method: BenchMethod = method, tier: Int = 1
  ) -> BenchIndexEntry {
    var result = BenchResult(
      system: .codevisor, scene: scroll.scene, resolution: scroll.resolution, network: scroll.network, repetition: 1,
      seed: 7)
    result.e2eMs = BenchDistribution([e2eP50Ms])
    let run = BenchRun(
      id: id, tier: tier, startedAt: Date(timeIntervalSince1970: 1_793_268_000), gitSha: "e3e2b0613",
      trigger: trigger, method: method)
    return BenchIndexEntry(
      run: run, path: "runs/2026/10/29/\(id)-tier\(tier).json", cells: BenchCellSummary.summaries([result]))
  }
}
