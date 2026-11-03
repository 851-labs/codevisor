import AppKit
import ScreenSharingBench

struct InjectCommand: BenchCommand {
  static let name = "inject"
  static let summary = "Post seeded space presses and clicks to the frontmost app and log when each was posted"
  static let usage =
    "--output <events.jsonl> [--keys 200] [--clicks 200] [--seed 7] [--duration <seconds>] [--start-delay <seconds>] "
    + DisplayOption.usage

  private static let counts = 0...2000
  private static let durations = 1...7200
  private static let startDelays = 0...600

  let presentsWindows = false
  private let output: String
  private let schedule: BenchInputSchedule
  private let startDelay: Duration
  private let display: CGDirectDisplayID?

  init(options: BenchOptions) throws {
    output = try options.requiredString("output")
    schedule = BenchInputSchedule(
      keys: try options.integer("keys", default: 200, in: Self.counts),
      clicks: try options.integer("clicks", default: 200, in: Self.counts),
      seed: UInt64(try options.integer("seed", default: 7, in: 0...Int.max)))
    startDelay = .seconds(try options.integer("start-delay", default: 0, in: Self.startDelays))
    display = try DisplayOption.id(from: options)
    let durationS = try options.integer("duration", default: 120, in: Self.durations)
    guard schedule.totalMs <= Double(durationS) * 1000 else {
      throw BenchUsageError(message: "the events take \(Int(schedule.totalMs / 1000)) s, longer than --duration")
    }
  }

  func run() async throws {
    try InputPoster.requireAccess()
    try await Task.sleep(for: startDelay)
    let target = Self.clickTarget(on: display ?? CGMainDisplayID())
    var injection = InputInjection()
    for step in schedule.steps {
      try await Task.sleep(for: .milliseconds(step.waitMs))
      try injection.post(step.kind, clickingAt: target)
    }
    try BenchOutput.writeLines(injection.events, to: output)
    try BenchOutput.print(InjectResult(injection, target: target))
  }

  private static func clickTarget(on display: CGDirectDisplayID) -> CGPoint {
    let bounds = CGDisplayBounds(display)
    return CGPoint(x: bounds.midX, y: bounds.midY)
  }
}
