import Foundation

public enum EphemeralSetupStage: Int, CaseIterable, Sendable {
  case starting
  case syncing
  case cloning

  public init?(serverState: String) {
    switch serverState {
    case "creating", "bootstrapping": self = .starting
    case "syncing": self = .syncing
    case "cloning": self = .cloning
    default: return nil
    }
  }
}

public enum EphemeralSetupTransition: Equatable, Sendable {
  case begin(EphemeralSetupStage)
  case succeed(EphemeralSetupStage)
}

public struct EphemeralSetupSteps: Sendable {
  public let target: EphemeralTarget
  public let projectName: String

  public init(target: EphemeralTarget, projectName: String) {
    self.target = target
    self.projectName = projectName
  }

  public static func phaseId(_ stage: EphemeralSetupStage) -> String {
    "ephemeral-\(stage)"
  }

  public static func transitions(
    from current: EphemeralSetupStage?,
    to next: EphemeralSetupStage?
  ) -> [EphemeralSetupTransition] {
    let last = next ?? EphemeralSetupStage.cloning
    let first = current.map(\.rawValue) ?? -1
    guard last.rawValue > first || next == nil else { return [] }

    var transitions: [EphemeralSetupTransition] = current.map { [.succeed($0)] } ?? []
    for stage in EphemeralSetupStage.allCases where stage.rawValue > first && stage.rawValue <= last.rawValue {
      transitions.append(.begin(stage))
      if stage != next { transitions.append(.succeed(stage)) }
    }
    return transitions
  }

  public func phase(_ stage: EphemeralSetupStage) -> SessionSetupPhase {
    let titles = titles(for: stage)
    return SessionSetupPhase(
      id: Self.phaseId(stage),
      activeTitle: titles.active,
      completedTitle: titles.completed,
      failedTitle: titles.failed
    )
  }

  public func status(_ stage: EphemeralSetupStage) -> String {
    "\(titles(for: stage).active)…"
  }

  private func titles(for stage: EphemeralSetupStage) -> (active: String, completed: String, failed: String) {
    switch stage {
    case .starting:
      ("Starting \(target.machineNoun)", "Started \(target.machineNoun)", "Could not start \(target.machineNoun)")
    case .syncing:
      ("Syncing your setup", "Synced your setup", "Could not sync your setup")
    case .cloning:
      ("Cloning \(projectName)", "Cloned \(projectName)", "Could not clone \(projectName)")
    }
  }
}
