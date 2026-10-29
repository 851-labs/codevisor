import Foundation
import ScreenSharingBench
import ScreenSharingBenchScenes

struct LoopbackCommand: BenchCommand {
  static let name = "loopback"
  static let summary =
    "Tier 1: stream synthetic scenes through the product sender and receiver over an emulated network"
  static let usage = [
    "[--scenes <scene,…>] [--networks <N0,…>] [--duration <seconds>] [--warm-up <seconds>] [--seed <n>]",
    "[--resolution R1] [--source synthetic|own-window] [--display main|virtual] [--onscreen]",
    "[--output <report.json>] [--frames <frames.jsonl>] [--run-id <id>] [--trigger <name>]",
  ].joined(separator: " ")

  private static let durations = 2...600

  private let scenes: [BenchScene]
  private let networks: [BenchNetworkConditions]
  private let settings: LoopbackSettings
  private let output: String?
  private let framesPath: String?
  private let runID: String?
  private let trigger: String

  init(options: BenchOptions) throws {
    scenes = try LoopbackMatrix.scenes(try options.string("scenes"))
    networks = try LoopbackMatrix.networks(try options.string("networks"))
    let duration = try options.integer("duration", default: 12, in: Self.durations)
    settings = LoopbackSettings(
      durationSeconds: duration, warmUpSeconds: try options.integer("warm-up", default: 5, in: 0...(duration - 1)),
      seed: UInt64(try options.integer("seed", default: 7, in: 0...Int(Int32.max))),
      resolution: try LoopbackMatrix.resolution(try options.choice("resolution", default: .r1)),
      endpoint: try options.flag("onscreen") ? .onGlass : .committed,
      source: try options.choice("source", default: .synthetic),
      display: try options.choice("display", default: .main))
    output = try LoopbackMatrix.writablePath(try options.string("output"))
    framesPath = try LoopbackMatrix.writablePath(try options.string("frames"))
    runID = try options.string("run-id")
    trigger = try options.string("trigger", default: "manual")
  }

  func run() async throws {
    let started = Date()
    let clock = ContinuousClock()
    let began = clock.now
    let environment = LoopbackEnvironment.current(settings)
    let outcomes = try await runMatrix()
    let report = BenchReport(run: run(startedAt: started), environment: environment, results: outcomes.map(\.result))

    try write(report, frames: outcomes.flatMap(\.frames))
    BenchConsole.error(LoopbackSummary.markdown(report, elapsed: clock.now - began))
    FileHandle.standardOutput.write(try BenchReportCodec.encode(report) + Data("\n".utf8))
  }

  private func runMatrix() async throws -> [LoopbackOutcome] {
    let cells = scenes.flatMap { scene in
      networks.map { LoopbackCell(scene: scene, conditions: $0, settings: settings) }
    }
    var outcomes: [LoopbackOutcome] = []
    for (index, cell) in cells.enumerated() {
      let outcome = await LoopbackAttempt.run(cell)
      BenchConsole.error(LoopbackSummary.progress(outcome, index: index, of: cells.count))
      outcomes.append(outcome)
    }
    return outcomes
  }

  private func run(startedAt started: Date) -> BenchRun {
    let commit = Bundle.main.object(forInfoDictionaryKey: "CodevisorBenchCommit") as? String
    return BenchRun(
      id: runID ?? "local-\(Int(started.timeIntervalSince1970))", tier: 1, startedAt: started,
      gitSha: commit ?? "unknown", trigger: trigger)
  }

  private func write(_ report: BenchReport, frames: [LoopbackFrameLine]) throws {
    if let output { try BenchReportCodec.write(report, to: URL(fileURLWithPath: output)) }
    if let framesPath { try BenchOutput.writeLines(frames, to: framesPath) }
  }
}
