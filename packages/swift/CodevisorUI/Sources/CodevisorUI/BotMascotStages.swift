@MainActor
final class BotMascotStages {
  static let shared = BotMascotStages()

  private var stages: [BotMascotStageKey: BotMascotStage] = [:]

  func stage(for key: BotMascotStageKey) -> BotMascotStage {
    if let stage = stages[key] { return stage }

    let stage = BotMascotStage()
    stages[key] = stage
    return stage
  }
}
