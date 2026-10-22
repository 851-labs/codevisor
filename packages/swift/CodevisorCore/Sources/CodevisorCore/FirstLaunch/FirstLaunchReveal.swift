public enum FirstLaunchReveal {
  public static func revealed(
    _ outcomes: [FirstLaunchStep: FirstLaunchStepOutcome]
  ) -> [FirstLaunchStep: FirstLaunchStepOutcome] {
    var revealed: [FirstLaunchStep: FirstLaunchStepOutcome] = [:]
    var everyStepAboveIsComplete = true
    for step in FirstLaunchStep.allCases {
      let actual = outcomes[step, default: .pending]
      let shown = actual.isComplete && !everyStepAboveIsComplete ? FirstLaunchStepOutcome.running : actual
      revealed[step] = shown
      everyStepAboveIsComplete = everyStepAboveIsComplete && shown.isComplete
    }
    return revealed
  }
}
