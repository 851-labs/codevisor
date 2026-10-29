import AppKit
import ScreenSharingBenchScenes

struct PlayerCommand: BenchCommand {
  static let name = "player"
  static let summary = "Draw a scripted scene full screen, one barcode version per content change"
  static let usage = """
    [--scene \(BenchScene.allCases.map(\.rawValue).joined(separator: "|"))] [--seed <n>] [--duration <seconds>]
      [--resolution native|R1|R2|R3] [--display main|virtual] [--input-region large|small]
      [--hash-log <path>] [--self-input-hz <n>]
    """

  private static let durations = 1...3600
  private static let selfInputRates = 0...60

  private let configuration: PlayerConfiguration

  init(options: BenchOptions) throws {
    configuration = PlayerConfiguration(
      scene: try options.choice("scene", default: BenchScene.video),
      seed: UInt64(try options.integer("seed", default: 1, in: 0...Int.max)),
      duration: try options.integer("duration", default: 60, in: Self.durations),
      resolution: try options.choice("resolution", default: SceneResolutionChoice.native),
      display: try options.choice("display", default: PlayerDisplayChoice.main),
      inputRegion: try options.choice("input-region", default: BenchInputRegion.large),
      hashLog: try options.string("hash-log"),
      selfInputHz: try options.integer("self-input-hz", default: 0, in: Self.selfInputRates))
  }

  func run() async throws {
    let report = try await PlayerSession(configuration).run()
    print(try report.json())
  }
}
