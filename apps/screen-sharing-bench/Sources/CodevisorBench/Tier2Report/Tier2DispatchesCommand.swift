import Foundation
import ScreenSharingBench

struct Tier2DispatchesCommand: BenchCommand {
  static let name = "tier2-dispatches"
  static let summary =
    "Summarize several Tier 2 dispatches: each one's display phase and v2 verdicts, and Apple HP across them"
  static let usage = "--reports <directory with one <label>/report.json per dispatch> [--markdown <summary.md>]"

  let presentsWindows = false
  private let reports: URL
  private let markdown: String?

  init(options: BenchOptions) throws {
    guard let reports = try options.string("reports") else { throw BenchUsageError(message: "--reports is required") }

    self.reports = URL(fileURLWithPath: reports)
    markdown = try options.string("markdown")
  }

  func run() async throws {
    let dispatches = try Self.load(reports)
    guard !dispatches.isEmpty else { throw BenchUsageError(message: "no <label>/report.json under \(reports.path)") }

    let text = Tier2DispatchesMarkdown(dispatches).text
    if let markdown { try text.write(toFile: markdown, atomically: true, encoding: .utf8) }
    print(text)
  }

  private static func load(_ directory: URL) throws -> [Tier2Dispatch] {
    let directories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try directories.compactMap { directory in
      let file = directory.appending(path: "report.json")
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }

      return Tier2Dispatch(
        label: directory.lastPathComponent, report: try BenchReportCodec.decode(Data(contentsOf: file)))
    }
  }
}

struct Tier2Dispatch {
  let label: String
  let report: BenchReport

  var parity: Tier2PhaseParity {
    Tier2PhaseParity(results: report.results)
  }
}
