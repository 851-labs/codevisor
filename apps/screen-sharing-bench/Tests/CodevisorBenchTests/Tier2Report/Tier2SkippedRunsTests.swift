import Foundation
import Testing

@testable import CodevisorBench

struct Tier2SkippedRunsTests {
  @Test func listsEveryPlannedRunWithoutAMeasurementAndWhyItWasSkipped() throws {
    let runs = try Self.runs([
      "01-scroll-floor-1": [:],
      "02-scroll-apple-hp-warm-up": [:],
      "03-scroll-apple-hp-1": ["viewer-skipped.txt": "apple-hp did not become ready\n"],
      "04-scroll-codevisor-v2-1": [
        "host-skipped.txt": "not ready at start\n", "viewer-skipped.txt": "not ready at start\n",
      ],
      "05-scroll-codevisor-v2-vcp-1": [:],
      "06-scroll-apple-hp-2": [:],
    ])

    let skipped = try Tier2SkippedRuns(
      in: runs, measured: ["01-scroll-floor-1", "06-scroll-apple-hp-2"],
      unreadable: ["06-scroll-apple-hp-2": "ignored for a measured run"])

    #expect(
      skipped.runs == [
        Tier2SkippedRun(name: "03-scroll-apple-hp-1", reasons: ["viewer: apple-hp did not become ready"]),
        Tier2SkippedRun(
          name: "04-scroll-codevisor-v2-1", reasons: ["host: not ready at start", "viewer: not ready at start"]),
        Tier2SkippedRun(name: "05-scroll-codevisor-v2-vcp-1", reasons: ["no measurement and no reason recorded"]),
      ])
  }

  @Test func aSkippedWarmUpCountsButAnUnmeasuredOneIsExpected() throws {
    let runs = try Self.runs(["02-typing-apple-hp-warm-up": ["viewer-skipped.txt": "apple-hp did not become ready"]])

    let skipped = try Tier2SkippedRuns(in: runs, measured: [], unreadable: [:])

    #expect(skipped.runs.map(\.name) == ["02-typing-apple-hp-warm-up"])
  }

  @Test func aRunWhoseFilesCannotBeReadCountsAsNotMeasured() throws {
    let runs = try Self.runs(["07-scroll-apple-hp-2": [:]])

    let skipped = try Tier2SkippedRuns(in: runs, measured: [], unreadable: ["07-scroll-apple-hp-2": "no viewer.jsonl"])

    #expect(skipped.runs.map(\.reasons) == [["its files could not be read: no viewer.jsonl"]])
  }

  @Test func theWarningOpensTheSummaryOnlyWhenRunsAreMissing() {
    let complete = Tier2SkippedRuns([])
    let incomplete = Tier2SkippedRuns([
      Tier2SkippedRun(name: "16-window-drag-floor-1", reasons: ["viewer: the host could not start"])
    ])

    #expect(complete.warning == nil)
    #expect(
      incomplete.warning
        == "**⚠️ Incomplete: 1 planned run was not measured, so this dispatch fails and is not a full comparison.** "
        + "Not measured: `16-window-drag-floor-1` (viewer: the host could not start).")
  }

  @Test func theListTravelsBesideTheReportToTheAcrossDispatchesSummary() throws {
    let report = try Self.runs([:]).appending(path: "report.json")
    let skipped = Tier2SkippedRuns([
      Tier2SkippedRun(name: "03-scroll-apple-hp-1", reasons: ["viewer: not ready at start"])
    ])

    try skipped.write(beside: report)

    #expect(try Tier2SkippedRuns(beside: report) == skipped)
  }

  private static func runs(_ directories: [String: [String: String]]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "f00\n".write(to: root.appending(path: "installed-commit.txt"), atomically: true, encoding: .utf8)
    for (name, files) in directories {
      let directory = root.appending(path: name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (file, contents) in files {
        try contents.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
      }
    }
    return root
  }
}
