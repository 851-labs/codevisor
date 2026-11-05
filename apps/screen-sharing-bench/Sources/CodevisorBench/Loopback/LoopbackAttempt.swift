import ScreenSharingBench

@MainActor
enum LoopbackAttempt {
  static func run(_ cell: LoopbackV2Cell) async -> LoopbackOutcome {
    do {
      return try await cell.run()
    } catch {
      var result = BenchResult(
        system: cell.settings.system, scene: cell.scene.rawValue, resolution: cell.settings.resolution.rawValue,
        network: cell.conditions.id, repetition: cell.repetition, seed: cell.settings.seed)
      result.valid = false
      result.invalidReason = "the scene failed: \(error)"
      return LoopbackOutcome(result: result, frames: [])
    }
  }
}
