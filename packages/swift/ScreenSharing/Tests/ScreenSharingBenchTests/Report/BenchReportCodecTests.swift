import Foundation
import ScreenSharingBench
import Testing

struct BenchReportCodecTests {
  @Test func theWriterMatchesTheGoldenReportAndTheGoldenReadsBack() throws {
    let golden = try golden()

    let written = try BenchReportCodec.encode(BenchReportFixture.report)

    #expect(try json(written) == json(golden))
    #expect(try BenchReportCodec.decode(golden) == BenchReportFixture.report)
  }

  @Test func reportsThatBreakTheSchemaAreRejected() throws {
    var report = BenchReportFixture.report
    report.schema = "codevisor.screen-sharing.bench/v0"
    report.run.tier = 4
    report.results[0].shownRatio = 1.2
    report.results[0].valid = false
    report.results[1].seed = 1 << 60
    report.comparisons[0].noiseBandMs = -1

    #expect(
      throws: BenchReportError.invalid([
        "schema is codevisor.screen-sharing.bench/v0, expected codevisor.screen-sharing.bench/v1",
        "run.tier 4 is not 1, 2 or 3",
        "results[0]: shown_ratio 1.2 is outside 0…1",
        "results[0]: valid must be true exactly when invalid_reason is absent",
        "results[1]: seed 1152921504606846976 is above 2^53 − 1, which JSON readers round",
        "comparisons[0]: noise_band_ms -1.0 is negative",
      ])
    ) { try BenchReportCodec.encode(report) }
  }

  @Test func aDistributionOutOfOrderDoesNotDecode() throws {
    var report = try #require(JSONSerialization.jsonObject(with: golden()) as? [String: Any])
    var calibration = try #require(report["calibration"] as? [String: Any])
    var agreement = try #require(calibration["observer_agreement_ms"] as? [String: Any])
    agreement["p95"] = -1
    calibration["observer_agreement_ms"] = agreement
    report["calibration"] = calibration

    #expect(throws: DecodingError.self) {
      try BenchReportCodec.decode(JSONSerialization.data(withJSONObject: report))
    }
  }

  @Test func startTimesWithFractionalSecondsDecode() throws {
    var report = try #require(JSONSerialization.jsonObject(with: golden()) as? [String: Any])
    var run = try #require(report["run"] as? [String: Any])
    run["started_at"] = "2026-10-29T10:00:00.250Z"
    report["run"] = run

    let decoded = try BenchReportCodec.decode(JSONSerialization.data(withJSONObject: report))

    #expect(decoded.run.startedAt == BenchReportFixture.report.run.startedAt.addingTimeInterval(0.25))
  }

  private func golden() throws -> Data {
    try Data(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/report", withExtension: "json")))
  }

  private func json(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }
}
