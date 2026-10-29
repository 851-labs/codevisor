import Foundation

struct GateCommand: BenchCommand {
  static let name = "gate"
  static let summary =
    "Compare two runs of the gate cells with the nightly baseline (design §4.2); exit 1 on a regression"
  static let usage = "--first <report.json> --second <report.json> [--index <index.jsonl>]"

  let presentsWindows = false
  private let firstPath: String
  private let secondPath: String
  private let indexPath: String?

  init(options: BenchOptions) throws {
    firstPath = try options.requiredString("first")
    secondPath = try options.requiredString("second")
    indexPath = try options.string("index")
  }

  func run() async throws {
    let gate = ResultsGate(
      first: try ResultsFiles.report(at: firstPath), second: try ResultsFiles.report(at: secondPath),
      index: try ResultsFiles.index(at: indexPath))
    FileHandle.standardOutput.write(Data((gate.markdown + "\n").utf8))
    guard !gate.failed else { throw GateRegressed() }
  }
}

struct GateRegressed: Error, CustomStringConvertible {
  let description = "a cell regressed in both runs"
}
