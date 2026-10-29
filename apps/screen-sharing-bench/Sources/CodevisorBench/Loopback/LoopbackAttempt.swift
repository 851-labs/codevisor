import ScreenSharingBench

@MainActor
enum LoopbackAttempt {
  static func run(_ cell: LoopbackCell) async -> LoopbackOutcome {
    do {
      return try await cell.run()
    } catch {
      var result = BenchResult(
        system: .codevisor, scene: cell.scene.rawValue, resolution: cell.settings.resolution.rawValue,
        network: cell.conditions.id, repetition: 1, seed: cell.settings.seed)
      result.valid = false
      result.invalidReason = "the scene failed: \(error)"
      return LoopbackOutcome(result: result, frames: [], qualityLevel: 0)
    }
  }
}
