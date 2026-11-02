import ScreenSharingBenchScenes

@MainActor
enum VirtualDisplayOption {
  static let usage = "[--virtual-display R1|R1x2|R2|R3]"

  static func read(from options: BenchOptions) throws -> BenchSceneResolution? {
    guard let text = try options.string("virtual-display") else { return nil }
    guard let resolution = BenchSceneResolution(rawValue: text) else {
      throw BenchUsageError(message: "--virtual-display takes R1, R1x2, R2 or R3, not \(text)")
    }

    return resolution
  }
}
