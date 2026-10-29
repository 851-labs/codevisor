import ScreenSharingBenchScenes

struct GenerateCommand: BenchCommand {
  static let name = "generate"
  static let summary =
    "Render scene versions offscreen (the Tier 1 generator): hashes, PNGs, or a check of a player hash log"
  static let usage = """
    [--scene <scene>] [--seed <n>] [--resolution R1|R2|R3] [--input-region large|small]
      [--first <version>] [--count <n>] [--png-dir <path>]
    or: --check <player hash log>
    """

  private static let counts = 1...100_000

  let presentsWindows = false
  private let plan: GeneratePlan

  init(options: BenchOptions) throws {
    if let log = try options.string("check") {
      plan = .check(try SceneHashLog.read(from: log))
      return
    }

    let resolution = try options.choice("resolution", default: BenchSceneResolution.r1)
    let setup = BenchSceneSetup(
      scene: try options.choice("scene", default: BenchScene.video),
      seed: UInt64(try options.integer("seed", default: 1, in: 0...Int.max)), canvas: BenchSceneCanvas(resolution),
      inputRegion: try options.choice("input-region", default: BenchInputRegion.large))
    let first = try options.integer("first", default: 0, in: 0...0xFF_FFFF)
    let count = try options.integer("count", default: 60, in: Self.counts)
    plan = .render(setup, versions: first..<min(first + count, 0x100_0000), pngDirectory: try options.string("png-dir"))
  }

  func run() async throws {
    switch plan {
    case .check(let log):
      let summary = try await GenerateCheck.run(log)
      print(try summary.json())
      if !summary.mismatched.isEmpty { throw GenerateError.hashMismatch(summary.mismatched.count) }
    case .render(let setup, let versions, let pngDirectory):
      try await GenerateRender.run(setup, versions: versions, pngDirectory: pngDirectory)
    }
  }
}
