import CodevisorCore

public enum ServerUpdateSteps {
  public static func steps(for activity: ServerUpdateActivity, isFailed: Bool) -> [ProgressStep] {
    let stages = ServerUpdateStage.allCases
    let skipped = Set(stages.filter(activity.stages.wasSkipped).map(\.rawValue))
    let states = ProgressStepSequence.states(
      count: stages.count,
      current: activity.stages.current.rawValue,
      isFailed: isFailed,
      skipped: skipped
    )
    return zip(stages, states).map { stage, state in
      ProgressStep(
        id: "server-update-\(stage)",
        title: stage.title,
        state: state,
        details: stage == activity.stages.current ? details(for: activity) : []
      )
    }
  }

  private static func details(for activity: ServerUpdateActivity) -> [String] {
    switch activity.stages.current {
    case .installing:
      activity.progress.map(ProgressStepDetailText.percent) ?? []
    case .updatingData:
      migrationDetails(activity.migration)
    case .pausingChats, .restarting, .reconnecting:
      []
    }
  }

  private static func migrationDetails(_ migration: ServerMigrationProgress?) -> [String] {
    guard let migration else { return [] }

    return ProgressStepDetailText.count(name: migration.name, completed: migration.completed, total: migration.total)
  }
}
