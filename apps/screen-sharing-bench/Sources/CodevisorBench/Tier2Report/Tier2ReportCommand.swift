import Foundation
import ScreenSharingBench

struct Tier2ReportCommand: BenchCommand {
  static let name = "tier2-report"
  static let summary = "Turn the Tier 2 workflow's merged results into the v1 report and the target table"
  static let usage = "--runs <directory> [--output <report.json>] [--markdown <summary.md>] [--run-id <id>]"

  let presentsWindows = false
  private let runs: URL
  private let output: String?
  private let markdown: String?
  private let runID: String

  init(options: BenchOptions) throws {
    guard let runs = try options.string("runs") else { throw BenchUsageError(message: "--runs is required") }

    self.runs = URL(fileURLWithPath: runs)
    output = try options.string("output")
    markdown = try options.string("markdown")
    runID = try options.string("run-id", default: self.runs.lastPathComponent)
  }

  func run() async throws {
    let measurements = try Self.load(runs)
    guard let environment = Tier2Environment.make(measurements) else {
      throw BenchUsageError(message: "no run in \(runs.path) has a host preflight")
    }

    let floors = Tier2Floors(measurements)
    let results = Self.results(measurements, floors: floors)
    let interference = Tier2Interference.make(measurements)
    let report = BenchReport(
      run: try Self.run(runID, measurements), environment: environment,
      calibration: BenchCalibration(
        nullSharingImageAgeMs: floors.pooledMs, observerInterference: Tier2Interference.calibration(interference)),
      results: results, comparisons: Tier2Comparisons.make(results))
    if let output { try BenchReportCodec.write(report, to: URL(fileURLWithPath: output)) }
    let summary = Tier2Markdown(report: report, floors: floors, interference: interference, measurements: measurements)
    if let markdown { try summary.text.write(toFile: markdown, atomically: true, encoding: .utf8) }
    print(summary.text)
  }

  private static func load(_ runs: URL) throws -> [Tier2Measurement] {
    let directories = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)
      .filter { FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path) }
    return directories.compactMap(measurement).sorted { $0.files.meta.index < $1.files.meta.index }
  }

  private static func measurement(_ directory: URL) -> Tier2Measurement? {
    do {
      return Tier2Measurement(try Tier2RunFiles(directory: directory))
    } catch {
      BenchConsole.error("skipping \(directory.lastPathComponent): \(error)")
      return nil
    }
  }

  private static func results(_ measurements: [Tier2Measurement], floors: Tier2Floors) -> [BenchResult] {
    measurements.filter(\.files.meta.hostObserver).compactMap(\.result).map { result in
      var result = result
      result.imageAgeAboveFloorMs = floors.aboveFloor(result)
      return result
    }
  }

  private static func run(_ id: String, _ measurements: [Tier2Measurement]) throws -> BenchRun {
    let first = measurements.first?.files.meta
    let startedAt = first.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) } ?? Date()
    return BenchRun(id: id, tier: 2, startedAt: startedAt, gitSha: first?.gitSha ?? "unknown", trigger: "manual")
  }
}
