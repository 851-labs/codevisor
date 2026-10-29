import Testing

@testable import CodevisorBench

@MainActor
struct BenchOptionsTests {
  @Test func readsSpacedAndInlineValuesAndBareFlags() throws {
    let options = try BenchOptions(["--scene", "video", "--seed=7", "--hash-log"])

    #expect(try options.string("scene") == "video")
    #expect(try options.integer("seed", default: 0) == 7)
    #expect(try options.flag("hash-log"))
    #expect(try options.integer("duration", default: 60) == 60)
    try options.rejectUnread()
  }

  @Test func rejectsOptionsNoCommandRead() throws {
    let options = try BenchOptions(["--scene", "video", "--sede", "7"])
    _ = try options.string("scene")

    #expect(throws: BenchUsageError(message: "unknown option --sede")) { try options.rejectUnread() }
  }

  @Test(arguments: [
    (["video"], "expected an option, not video"),
    (["--seed", "1", "--seed=2"], "--seed is given twice"),
  ])
  func rejectsMalformedArguments(arguments: [String], message: String) {
    #expect(throws: BenchUsageError(message: message)) { try BenchOptions(arguments) }
  }

  @Test func rejectsValuesOfTheWrongShape() throws {
    let options = try BenchOptions([
      "--seed", "seven", "--duration", "0", "--hash-log=yes", "--scene", "tetris", "--output", "--side=",
    ])

    #expect(throws: BenchUsageError(message: "--seed needs an integer in 0...9, not seven")) {
      try options.integer("seed", default: 0, in: 0...9)
    }
    #expect(throws: BenchUsageError(message: "--duration needs an integer in 1...60, not 0")) {
      try options.integer("duration", default: 5, in: 1...60)
    }
    #expect(throws: BenchUsageError(message: "--hash-log takes no value")) { try options.flag("hash-log") }
    #expect(throws: BenchUsageError(message: "--scene must be one of left, right, not tetris")) {
      try options.choice("scene", default: Side.left)
    }
    #expect(throws: BenchUsageError(message: "--output needs a value")) { try options.string("output") }
    #expect(throws: BenchUsageError(message: "--side needs a value")) { try options.choice("side", default: Side.left) }
  }
}

private enum Side: String, CaseIterable {
  case left
  case right
}
