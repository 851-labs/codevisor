import Foundation
import ScreenSharingBench

struct RecordCommand: BenchCommand {
  struct Recorded: Encodable {
    let report: String
    let chart: String
  }

  static let name = "record"
  static let summary = "Add a report to a benchmark-results checkout: the report, its chart and an index.jsonl line"
  static let usage = "--report <report.json> --results <benchmark-results checkout>"

  let presentsWindows = false
  private let reportPath: String
  private let results: URL

  init(options: BenchOptions) throws {
    reportPath = try options.requiredString("report")
    results = URL(fileURLWithPath: try options.requiredString("results"), isDirectory: true)
  }

  func run() async throws {
    let report = try ResultsFiles.report(at: reportPath)
    let index = results.appending(path: "index.jsonl")
    let history = ResultsHistory(report: report, index: try ResultsFiles.index(at: index.path))
    let stem = Self.stem(report.run)

    try FileManager.default.createDirectory(
      at: results.appending(path: stem).deletingLastPathComponent(), withIntermediateDirectories: true)
    try BenchReportCodec.write(report, to: results.appending(path: stem + ".json"))
    try Data(history.chart(title: report.run.id).svg.utf8).write(to: results.appending(path: stem + ".svg"))
    try append(BenchIndex.line(BenchIndexEntry(report: report, path: stem + ".json")), to: index)
    try BenchOutput.print(Recorded(report: stem + ".json", chart: stem + ".svg"))
  }

  static func stem(_ run: BenchRun) -> String {
    let day = run.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    return "runs/\(day.replacingOccurrences(of: "-", with: "/"))/\(run.id)-tier\(run.tier)"
  }

  private func append(_ line: Data, to index: URL) throws {
    guard FileManager.default.fileExists(atPath: index.path) else { return try line.write(to: index) }

    let handle = try FileHandle(forWritingTo: index)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }
}
