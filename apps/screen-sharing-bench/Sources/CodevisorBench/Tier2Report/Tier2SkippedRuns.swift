import Foundation

struct Tier2SkippedRuns: Equatable {
  static let fileName = "skipped-runs.json"
  private static let parties = ["host", "viewer"]
  private static let warmUpSuffix = "-warm-up"
  private static let unexplained = "no measurement and no reason recorded"

  let runs: [Tier2SkippedRun]

  init(_ runs: [Tier2SkippedRun]) {
    self.runs = runs
  }

  init(in directory: URL, measured: Set<String>, unreadable: [String: String]) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey])
    runs =
      entries
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .filter { !measured.contains($0.lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { Self.skipped($0, unreadable: unreadable[$0.lastPathComponent]) }
  }

  init(beside report: URL) throws {
    let file = report.deletingLastPathComponent().appending(path: Self.fileName)
    guard FileManager.default.fileExists(atPath: file.path) else {
      self.init([])
      return
    }

    self.init(try JSONDecoder().decode([Tier2SkippedRun].self, from: Data(contentsOf: file)))
  }

  var warning: String? {
    guard !runs.isEmpty else { return nil }

    return "**⚠️ Incomplete: \(count) not measured, so this dispatch fails and is not a full comparison.** "
      + "Not measured: " + runs.map(\.text).joined(separator: ", ") + "."
  }

  var count: String {
    runs.count == 1 ? "1 planned run was" : "\(runs.count) planned runs were"
  }

  func write(beside report: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(runs).write(to: report.deletingLastPathComponent().appending(path: Self.fileName))
  }

  private static func skipped(_ directory: URL, unreadable: String?) -> Tier2SkippedRun? {
    let name = directory.lastPathComponent
    let reasons = recorded(in: directory) + (unreadable.map { ["its files could not be read: \($0)"] } ?? [])
    guard reasons.isEmpty else { return Tier2SkippedRun(name: name, reasons: reasons) }
    guard !name.hasSuffix(warmUpSuffix) else { return nil }

    return Tier2SkippedRun(name: name, reasons: [unexplained])
  }

  private static func recorded(in directory: URL) -> [String] {
    parties.compactMap { party in
      let file = directory.appending(path: "\(party)-skipped.txt")
      guard let reason = try? String(contentsOf: file, encoding: .utf8) else { return nil }

      return "\(party): \(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
  }
}

struct Tier2RunsSkipped: Error, CustomStringConvertible {
  let skipped: Tier2SkippedRuns

  var description: String {
    "\(skipped.count) not measured: \(skipped.runs.map(\.name).joined(separator: ", "))"
  }
}
