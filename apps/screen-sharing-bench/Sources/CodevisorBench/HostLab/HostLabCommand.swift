import CoreGraphics
import Darwin
import Foundation
import ScreenSharingBenchScenes

struct HostLabCommand: BenchCommand {
  static let name = "host-lab"
  static let summary =
    "Measure the engine v2 host's CPU per variant on one Mac: a scene on a virtual display, captured and encoded"
  static let usage =
    "[--scenes <scene,…>] [--variants <variant/…>] [--seconds <n>] [--settle <n>] \(VirtualDisplayOption.usage) "
    + "[--output <file.json>] [--markdown <file.md>]; a variant is \(HostLabVariant.usage)"

  nonisolated static let groups = [
    "CodevisorBench:host-run", "VTEncoderXPCService", "WindowServer", "replayd", "CodevisorBench:player",
  ]
  private static let durations = 5...300
  private static let settles = 1...30
  private static let playerLeadSeconds = 5
  private static let childSlackSeconds = 3
  private static let variantStartupSeconds = 15

  let presentsWindows = false
  private let scenes: [BenchScene]
  private let variants: [HostLabVariant]
  private let seconds: Int
  private let settle: Int
  private let resolution: BenchSceneResolution
  private let output: String?
  private let markdown: String?

  init(options: BenchOptions) throws {
    scenes = try options.string("scenes", default: BenchScene.scroll.rawValue).split(separator: ",").map { name in
      guard let scene = BenchScene(rawValue: String(name)) else {
        throw BenchUsageError(message: "unknown scene \(name)")
      }

      return scene
    }
    variants = try options.string("variants", default: "base").split(separator: "/").map {
      try HostLabVariant(parsing: String($0))
    }
    seconds = try options.integer("seconds", default: 30, in: Self.durations)
    settle = try options.integer("settle", default: 5, in: Self.settles)
    resolution = try VirtualDisplayOption.read(from: options) ?? .r1HiDPI
    output = try options.string("output")
    markdown = try options.string("markdown")
  }

  func run() async throws {
    let display = try await SharedDisplay.make(resolution)
    defer { withExtendedLifetime(display) {} }
    var results: [HostLabResult] = []
    for scene in scenes {
      results += try await measure(scene, on: display.id)
    }
    let report = HostLabReport(resolution: resolution.rawValue, seconds: seconds, results: results)
    if let output { try BenchOutput.writeLines([report], to: output) }
    if let markdown { try report.markdown.write(toFile: markdown, atomically: true, encoding: .utf8) }
    BenchConsole.error(report.markdown)
    try BenchOutput.print(report)
  }

  private func measure(_ scene: BenchScene, on displayID: CGDirectDisplayID) async throws -> [HostLabResult] {
    let perVariant = seconds + settle + Self.childSlackSeconds + Self.variantStartupSeconds
    let player = try HostLabChild.launch([
      "player", "--scene", scene.rawValue, "--display-id", "\(displayID)", "--duration",
      "\(Self.playerLeadSeconds + perVariant * variants.count + 5)",
    ])
    defer { player.stop() }
    try await Task.sleep(for: .seconds(Self.playerLeadSeconds))
    var results: [HostLabResult] = []
    for variant in variants {
      results.append(try await measure(variant, scene: scene, on: displayID))
    }
    return results
  }

  private func measure(
    _ variant: HostLabVariant, scene: BenchScene, on displayID: CGDirectDisplayID
  ) async throws -> HostLabResult {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("host-run-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let child = try HostLabChild.launch(
      [
        "host-run", "--display-id", "\(displayID)", "--seconds", "\(settle + seconds + Self.childSlackSeconds)",
        "--output", file.path,
      ] + variant.arguments)
    defer { child.stop() }
    child.stop(after: .seconds(settle + seconds + Self.childSlackSeconds + Self.variantStartupSeconds))
    try await Task.sleep(for: .seconds(settle))
    let groups = Self.groups.map(ProcessGroup.init(name:))
    let start = try ProcessListing.capture()
    let before = groups.map { $0.sample(start) }
    try await Task.sleep(for: .seconds(seconds))
    let end = try ProcessListing.capture()
    let loads = zip(groups, zip(before, groups.map { $0.sample(end) })).map { group, pair in
      (group.name, ProcessGroup.load(from: pair.0, to: pair.1)?.cpuPercent)
    }
    let status = await child.wait()
    let run = try? JSONDecoder().decode(HostRunResult.self, from: Data(contentsOf: file))
    return HostLabResult(
      scene: scene.rawValue, variant: variant.name, exitStatus: status,
      cpuPct: Dictionary(uniqueKeysWithValues: loads.compactMap { name, load in load.map { (name, $0) } }),
      allProcesses: ProcessTotals(from: start, to: end), run: run, seconds: seconds)
  }
}
