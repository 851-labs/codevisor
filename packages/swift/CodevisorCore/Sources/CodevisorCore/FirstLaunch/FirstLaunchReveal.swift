public enum FirstLaunchReveal {
  public static func revealed(
    _ outcomes: [FirstLaunchStep: FirstLaunchStepOutcome]
  ) -> [FirstLaunchStep: FirstLaunchStepOutcome] {
    let current = FirstLaunchStep.allCases.first { !outcomes[$0, default: .pending].isComplete }
    return Dictionary(
      uniqueKeysWithValues: FirstLaunchStep.allCases.map { step in
        (step, shown(step, current: current, outcomes: outcomes))
      }
    )
  }

  private static func shown(
    _ step: FirstLaunchStep,
    current: FirstLaunchStep?,
    outcomes: [FirstLaunchStep: FirstLaunchStepOutcome]
  ) -> FirstLaunchStepOutcome {
    guard let current, step.rawValue >= current.rawValue else { return outcomes[step, default: .pending] }
    guard step == current else { return .pending }
    return outcomes[step] == .failed ? .failed : .running
  }
}
