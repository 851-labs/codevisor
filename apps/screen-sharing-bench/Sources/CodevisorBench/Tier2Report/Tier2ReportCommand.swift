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
    let loaded = try Self.load(runs)
    let measurements = loaded.measurements
    let skipped = try Tier2SkippedRuns(
      in: runs, measured: Set(measurements.map(\.files.directory.lastPathComponent)), unreadable: loaded.unreadable)
    guard let environment = Tier2Environment.make(measurements) else {
      throw BenchUsageError(message: "no run in \(runs.path) has a host preflight")
    }

    let floors = Tier2Floors(measurements)
    let inputFloors = Tier2InputFloors(measurements)
    let results = Self.results(measurements, floors: floors)
    let interference = Tier2Interference.make(measurements)
    let report = BenchReport(
      run: try Self.run(runID, measurements), environment: environment,
      calibration: BenchCalibration(
        nullSharingImageAgeMs: floors.pooledMs, localI2pMs: inputFloors.pooledMs,
        observerInterference: Tier2Interference.calibration(interference)),
      results: results, comparisons: Tier2Comparisons.make(results))
    if let output {
      try BenchReportCodec.write(report, to: URL(fileURLWithPath: output))
      try skipped.write(beside: URL(fileURLWithPath: output))
    }
    let summary = Tier2Markdown(
      report: report, floors: floors, inputFloors: inputFloors, interference: interference, measurements: measurements,
      skipped: skipped)
    if let markdown { try summary.text.write(toFile: markdown, atomically: true, encoding: .utf8) }
    print(summary.text)
    guard skipped.runs.isEmpty else { throw Tier2RunsSkipped(skipped: skipped) }
  }

  private struct Loaded {
    var measurements: [Tier2Measurement] = []
    var unreadable: [String: String] = [:]
  }

  private static func load(_ runs: URL) throws -> Loaded {
    let directories = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)
      .filter { FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path) }
    var loaded = directories.reduce(into: Loaded(), read)
    loaded.measurements.sort { $0.files.meta.index < $1.files.meta.index }
    return loaded
  }

  private static func read(_ loaded: inout Loaded, _ directory: URL) {
    do {
      loaded.measurements.append(Tier2Measurement(try Tier2RunFiles(directory: directory)))
    } catch {
      BenchConsole.error("could not read \(directory.lastPathComponent): \(error)")
      loaded.unreadable[directory.lastPathComponent] = "\(error)"
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
