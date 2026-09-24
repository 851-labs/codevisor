import Foundation
import Testing

@testable import ScreenSharingRigKit

/// The pure half of `vnc-bench` (851-2310): statistics, aggregation across
/// runs, the noise band and the baseline comparison.
struct VNCBenchTests {
  @Test func percentilesUseNearestRank() {
    let values: [Double] = [5, 1, 4, 2, 3]
    #expect(VNCBenchStatistics.median(values) == 3)
    #expect(VNCBenchStatistics.percentile(values, 0.95) == 5)
    #expect(VNCBenchStatistics.percentile([7], 0.5) == 7)
    #expect(VNCBenchStatistics.median([]) == nil)
  }

  @Test func aCaseReportsTheMedianRunAndItsSpread() throws {
    let runs: [[VNCBenchMetric: Double]] = [
      [.updatesPerSecond: 90, .updateLatencyP95Ms: 12],
      [.updatesPerSecond: 100, .updateLatencyP95Ms: 10],
      [.updatesPerSecond: 110, .updateLatencyP95Ms: 11],
    ]
    let result = VNCBenchCase(scene: "scroll", profile: "wan150", runs: runs)
    #expect(result.median[.updatesPerSecond] == 100)
    #expect(result.median[.updateLatencyP95Ms] == 11)
    // Largest relative distance of a run from the median.
    #expect(result.spread[.updatesPerSecond] == 0.1)
    #expect(abs(try #require(result.spread[.updateLatencyP95Ms]) - 1.0 / 11) < 1e-9)
  }

  @Test func directionsSayWhatBetterMeans() {
    #expect(VNCBenchMetric.updatesPerSecond.direction == .higherIsBetter)
    #expect(VNCBenchMetric.updateLatencyP95Ms.direction == .lowerIsBetter)
    #expect(VNCBenchMetric.cpuMsPerUpdate.direction == .informational, "too noisy to judge (851-2320)")
    #expect(VNCBenchMetric.megabitsPerSecond.direction == .informational)
  }

  @Test func comparisonFlagsOnlyChangesBeyondTheNoiseBand() {
    func report(_ ups: Double, latency: Double, mbps: Double, spread: Double) -> VNCBenchReport {
      var result = VNCBenchCase(
        scene: "typing", profile: "lan",
        runs: [[.updatesPerSecond: ups, .updateLatencyP95Ms: latency, .megabitsPerSecond: mbps]])
      result.spread = [.updatesPerSecond: spread, .updateLatencyP95Ms: spread, .megabitsPerSecond: spread]
      return VNCBenchReport(machine: .init(model: "Mac16,5", system: "27.2", power: "AC"), build: "x", cases: [result])
    }
    let baseline = report(100, latency: 20, mbps: 5, spread: 0.02)
    // Within max(spread, 10 %): no verdict either way.
    #expect(
      VNCBenchComparison(baseline: baseline, current: report(92, latency: 20.9, mbps: 9, spread: 0.02)).regressions
        .isEmpty)
    let worse = VNCBenchComparison(baseline: baseline, current: report(80, latency: 30, mbps: 5, spread: 0.02))
    #expect(worse.regressions.map(\.metric) == [.updatesPerSecond, .updateLatencyP95Ms])
    let better = VNCBenchComparison(baseline: baseline, current: report(150, latency: 10, mbps: 1, spread: 0.02))
    #expect(better.regressions.isEmpty)
    #expect(better.improvements.map(\.metric) == [.updatesPerSecond, .updateLatencyP95Ms])
    // A noisy baseline widens the band.
    let noisy = report(100, latency: 20, mbps: 5, spread: 0.3)
    #expect(
      VNCBenchComparison(baseline: noisy, current: report(80, latency: 25, mbps: 5, spread: 0.02)).regressions.isEmpty)
  }

  @Test func cpuPerUpdateIsReportedButNeverAVerdict() {
    func report(_ cpu: Double) -> VNCBenchReport {
      VNCBenchReport(
        machine: .init(model: "m", system: "s", power: "AC"), build: "b",
        cases: [VNCBenchCase(scene: "typing", profile: "wan150", runs: [[.cpuMsPerUpdate: cpu]])])
    }
    let comparison = VNCBenchComparison(baseline: report(0.54), current: report(1.31))
    #expect(comparison.regressions.isEmpty && comparison.improvements.isEmpty)
    #expect(comparison.rows.first?.verdict == .informational)
  }

  @Test func sub_millisecondLatencyChangesAreNoise() {
    func report(_ latency: Double) -> VNCBenchReport {
      VNCBenchReport(
        machine: .init(model: "m", system: "s", power: "AC"), build: "b",
        cases: [VNCBenchCase(scene: "typing", profile: "lan", runs: [[.updateLatencyP50Ms: latency]])])
    }
    #expect(VNCBenchComparison(baseline: report(0.4), current: report(0.9)).regressions.isEmpty)
    #expect(VNCBenchComparison(baseline: report(0.4), current: report(1.5)).regressions.count == 1)
  }

  @Test func casesMissingOnEitherSideAreListedNotCompared() {
    let a = VNCBenchReport(
      machine: .init(model: "m", system: "s", power: "AC"), build: "a",
      cases: [VNCBenchCase(scene: "typing", profile: "lan", runs: [[.updatesPerSecond: 10]])])
    let b = VNCBenchReport(
      machine: .init(model: "m", system: "s", power: "AC"), build: "b",
      cases: [VNCBenchCase(scene: "scroll", profile: "lan", runs: [[.updatesPerSecond: 10]])])
    let comparison = VNCBenchComparison(baseline: a, current: b)
    #expect(comparison.rows.isEmpty)
    #expect(comparison.unmatched == ["scroll/lan", "typing/lan"])
  }

  @Test func reportsRoundTripThroughJSONAndRenderMarkdown() throws {
    let report = VNCBenchReport(
      machine: .init(model: "Mac16,5", system: "27.2", power: "AC"), build: "abc123",
      cases: [
        VNCBenchCase(scene: "scroll", profile: "wan150", runs: [[.updatesPerSecond: 6.5, .updateLatencyP95Ms: 160]])
      ])
    let decoded = try JSONDecoder().decode(VNCBenchReport.self, from: try report.json())
    #expect(decoded == report)
    let markdown = report.markdown()
    #expect(markdown.contains("| scroll | wan150 |"))
    #expect(markdown.contains("6.5"))
    #expect(markdown.contains("Mac16,5"))
  }

  @Test func optionsParseTheMatrixAndOutputs() throws {
    let options = try VNCBenchOptions(arguments: [
      "--scenes", "typing,scroll", "--profiles", "lan", "--runs", "2", "--frames", "10", "--size", "640x400",
      "--out", "/tmp/x", "--baseline", "/tmp/b.json", "--build", "abc",
    ])
    #expect(options.scenes == ["typing", "scroll"])
    #expect(options.profiles == ["lan"])
    #expect(options.runs == 2 && options.frames == 10)
    #expect(options.width == 640 && options.height == 400)
    #expect(options.output == "/tmp/x" && options.baseline == "/tmp/b.json" && options.build == "abc")
    #expect(throws: (any Error).self) { try VNCBenchOptions(arguments: ["--scenes", "nope"]) }
    #expect(throws: (any Error).self) { try VNCBenchOptions(arguments: ["--profiles", "mars"]) }
    let defaults = try VNCBenchOptions(arguments: [])
    #expect(defaults.scenes == ["typing", "scroll", "photo", "input"])
    #expect(defaults.profiles == ["lan", "wan150"])
    #expect(defaults.pace == 60)
    #expect(defaults.quality == nil)
    #expect(try VNCBenchOptions(arguments: ["--quality", "8"]).quality == 8)
    #expect(throws: (any Error).self) { try VNCBenchOptions(arguments: ["--quality", "10"]) }
    #expect(try VNCBenchOptions(arguments: ["--pace", "0"]).pace == 0)
    #expect(throws: (any Error).self) { try VNCBenchOptions(arguments: ["--pace", "999"]) }
  }

  /// 851-2336: `--pace 0` plays a frame per request, so its server must not offer
  /// continuous updates (the client would stop requesting and the run would hang).
  @Test func requestDrivenScenesGetARequestOnlyServer() {
    let paced = VNCBenchServer.arguments(scene: "typing", echo: false, seed: 1, pace: 60, width: 640, height: 480)
    #expect(paced.contains("--scene-fps") && !paced.contains("--requested-only"))
    let onRequest = VNCBenchServer.arguments(scene: "photo", echo: false, seed: 1, pace: 0, width: 640, height: 480)
    #expect(onRequest.contains("--requested-only") && !onRequest.contains("--scene-fps"))
    #expect(Array(onRequest.prefix(3)) == ["vnc-server", "--port", "0"])
  }
}
