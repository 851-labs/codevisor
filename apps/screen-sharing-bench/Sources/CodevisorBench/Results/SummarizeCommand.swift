import Foundation

struct SummarizeCommand: BenchCommand {
  static let name = "summarize"
  static let summary = "Print the Markdown job summary of a report, with deltas and trends from index.jsonl"
  static let usage = "--report <report.json> [--index <index.jsonl>] [--chart-url <url>] [--preflight <preflight.json>]"

  let presentsWindows = false
  private let reportPath: String
  private let indexPath: String?
  private let chartURL: String?
  private let preflightPath: String?

  init(options: BenchOptions) throws {
    reportPath = try options.requiredString("report")
    indexPath = try options.string("index")
    chartURL = try options.string("chart-url")
    preflightPath = try options.string("preflight")
  }

  func run() async throws {
    let history = ResultsHistory(
      report: try ResultsFiles.report(at: reportPath), index: try ResultsFiles.index(at: indexPath))
    let markdown = ResultsMarkdown(
      history: history, chartURL: chartURL, preflight: try ResultsPreflight.read(preflightPath))
    FileHandle.standardOutput.write(Data((markdown.text + "\n").utf8))
  }
}
