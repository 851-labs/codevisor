import CodevisorCore

struct ServerAvailabilitySteps {
  let availability: ServerAvailability
  let machineName: String
  let isLocal: Bool
  let startupProgress: LocalServerStartupProgress?
  let appUpdate: AppUpdateActivity?
  let serverUpdate: ServerUpdateActivity?

  var steps: [ProgressStep] {
    if let appUpdate { return AppUpdateSteps.steps(for: appUpdate) }
    if let serverUpdate { return ServerUpdateSteps.steps(for: serverUpdate, isFailed: isFailed) }
    if isLocal { return LocalServerStartupSteps.steps(for: startupProgress, isFailed: isFailed) }
    return remoteSteps
  }

  private var isFailed: Bool {
    if case .failed = availability { return true }
    return startupProgress?.state == "failed"
  }

  private var remoteSteps: [ProgressStep] {
    switch availability {
    case .waiting(.connecting), .waiting(.starting):
      [step(connectingTitle, .running)]
    case .waiting(.updating):
      [step(ServerUpdateStage.installing.title, .running)]
    case .waiting(.restarting):
      [step(ServerUpdateStage.restarting.title, .running), step(ServerUpdateStage.reconnecting.title, .pending)]
    case .ready:
      [step(connectingTitle, .done)]
    case .failed:
      [step(connectingTitle, .failed)]
    }
  }

  private var connectingTitle: String {
    "Connecting to \(machineName)"
  }

  private func step(_ title: String, _ state: ProgressStepState) -> ProgressStep {
    ProgressStep(id: title, title: title, state: state)
  }
}
