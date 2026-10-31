import Foundation
import ScreenSharingBenchScenes

struct EncodeLabCommand: BenchCommand {
  static let name = "encode-lab"
  static let summary =
    "Encode scene frames offscreen with VideoToolbox configs; report encode time, bits, PSNR/SSIM and refresh cost"
  static let usage = """
    [--scenes idle-cursor,typing,…] [--resolution R1x2] [--configs "name=a,codec=hevc,rc=ll,mbps=8;…"]
      [--duration 8] [--warm-up 2] [--quality-samples 24] [--seed 1] [--output <file.json>] [--markdown <file.md>]
    config keys: name engine(vt|vcp) codec(hevc444|hevc|h264) rc(standard|ll) mbps(<n>|none) size(<w>x<h>) tiles
      skip ltr yuv speed mfd qpmax qpmin drl(<mbps>@<s>) preset(vc|speed|balanced|quality) cq(0–1) aq ackms refine vcpin
    """

  let presentsWindows = false
  private let plan: EncodeLabPlan

  init(options: BenchOptions) throws {
    let ticksPerSecond = BenchSceneTimeline.ticksPerSecond
    let duration = try options.integer("duration", default: 8, in: 1...120)
    let warmUp = try options.integer("warm-up", default: 2, in: 0...30)
    guard warmUp < duration else { throw BenchUsageError(message: "--warm-up must be shorter than --duration") }

    plan = EncodeLabPlan(
      scenes: try Self.scenes(try options.string("scenes")),
      configs: try EncodeLabConfigParser.parse(list: try options.string("configs", default: "name=product")),
      resolution: try options.choice("resolution", default: BenchSceneResolution.r1HiDPI),
      seed: UInt64(try options.integer("seed", default: 1, in: 0...Int.max)),
      durationTicks: duration * ticksPerSecond, warmUpTicks: warmUp * ticksPerSecond,
      qualitySamples: try options.integer("quality-samples", default: 24, in: 0...10_000),
      output: try options.string("output"), markdown: try options.string("markdown"))
  }

  func run() async throws {
    var results: [EncodeLabResult] = []
    for scene in plan.scenes {
      for config in plan.configs {
        let result = await EncodeLabCell(plan: plan, scene: scene, config: config).run()
        BenchConsole.error(EncodeLabTable.progressLine(result))
        results.append(result)
      }
    }
    try write(results)
  }

  private func write(_ results: [EncodeLabResult]) throws {
    let report = EncodeLabReport(resolution: plan.resolution.rawValue, results: results)
    if let output = plan.output { try BenchOutput.writeLines([report], to: output) }
    if let markdown = plan.markdown {
      try EncodeLabTable.markdown(results).write(toFile: markdown, atomically: true, encoding: .utf8)
    }
    try BenchOutput.print(report)
  }

  private static func scenes(_ list: String?) throws -> [BenchScene] {
    guard let list else { return EncodeLabPlan.defaultScenes }

    return try list.split(separator: ",").map { name in
      guard let scene = BenchScene(rawValue: String(name)), scene != .input else {
        throw BenchUsageError(message: "--scenes: unknown or input-driven scene \(name)")
      }

      return scene
    }
  }
}
