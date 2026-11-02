import CodevisorCore

public enum LocalServerStartupSteps {
  static let titles = [
    "Preparing background service",
    "Starting server process",
    "Loading server runtime",
    "Preparing database",
    "Restoring saved terminals",
    "Initializing server services",
    "Checking server connection",
  ]

  public static func steps(
    for progress: LocalServerStartupProgress?,
    isFailed: Bool,
    currentDetails: [String]? = nil
  ) -> [ProgressStep] {
    let current = progress?.completed ?? 0
    let states = ProgressStepSequence.states(count: titles.count, current: current, isFailed: isFailed)
    let details = currentDetails ?? Self.details(for: progress)
    return zip(titles.indices, states).map { index, state in
      ProgressStep(
        id: "startup-\(index)",
        title: titles[index],
        state: state,
        details: index == current ? details : []
      )
    }
  }

  private static func details(for progress: LocalServerStartupProgress?) -> [String] {
    if let work = progress?.work, work.total > 0 {
      return ProgressStepDetailText.count(name: work.name, completed: work.completed, total: work.total)
    }
    return progress?.stage == "acquiringDatabase" ? ["Waiting for access"] : []
  }
}
