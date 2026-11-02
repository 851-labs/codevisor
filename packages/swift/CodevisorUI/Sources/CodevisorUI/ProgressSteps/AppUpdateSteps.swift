import CodevisorCore

public enum AppUpdateSteps {
  public static func steps(for activity: AppUpdateActivity) -> [ProgressStep] {
    let stages = AppUpdateStage.allCases
    let states = ProgressStepSequence.states(count: stages.count, current: activity.stage.rawValue)
    return zip(stages, states).map { stage, state in
      ProgressStep(
        id: "app-update-\(stage)",
        title: stage.title,
        state: state,
        details: stage == activity.stage ? details(for: activity) : []
      )
    }
  }

  private static func details(for activity: AppUpdateActivity) -> [String] {
    if let progress = activity.progress { return ProgressStepDetailText.percent(progress) }
    return activity.statusMessage.map { [$0] } ?? []
  }
}
