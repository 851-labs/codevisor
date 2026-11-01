import ScreenSharingBench

@MainActor
enum LoopbackAttempt {
  static func run(_ cell: LoopbackCell) async -> LoopbackOutcome {
    do {
      switch cell.settings.engine {
      case .v1: return try await cell.run()
      case .v2:
        return try await LoopbackV2Cell(
          scene: cell.scene, conditions: cell.conditions, settings: cell.settings, repetition: cell.repetition
        ).run()
      }
    } catch {
      var result = BenchResult(
        system: cell.settings.system, scene: cell.scene.rawValue, resolution: cell.settings.resolution.rawValue,
        network: cell.conditions.id, repetition: cell.repetition, seed: cell.settings.seed)
      result.valid = false
      result.invalidReason = "the scene failed: \(error)"
      return LoopbackOutcome(result: result, frames: [], qualityLevel: 0)
    }
  }
}
