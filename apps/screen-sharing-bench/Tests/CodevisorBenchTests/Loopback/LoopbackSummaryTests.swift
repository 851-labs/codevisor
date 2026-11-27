import Foundation
import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct LoopbackSummaryTests {
  @Test func theLabTableShowsEachRunsGapsOverTheFixedThresholdsAndTheTimeInThem() {
    var result = BenchResult(
      system: .codevisorV2, scene: "scroll", resolution: "R1", network: "N7", repetition: 1, seed: 1)
    result.longGaps = BenchLongGaps(gapsMs: [300, 400, 600, 1_200, 100])
    let machine = BenchMachine(
      name: "tamale", chip: "M4", os: "26.0", display: "R1", load1AtStart: 1, thermal: "nominal",
      spotlightBusy: false)
    let report = BenchReport(
      run: BenchRun(id: "local-1", tier: 1, startedAt: Date(timeIntervalSince1970: 0), gitSha: "f00", trigger: "lab"),
      environment: BenchEnvironment(host: machine), results: [result])

    let lines = LoopbackSummary.markdown(report, elapsed: .seconds(60)).split(separator: "\n")
    let header = lines.first { $0.hasPrefix("| scene | network") }
    let row = lines.first { $0.hasPrefix("| scroll | N7") }

    #expect(header?.contains("| freezes | gaps > 250 ms | gaps > 500 ms |") == true)
    #expect(row?.contains("| – | 4 (2.5 s) | 2 (1.8 s) |") == true)
  }
}
