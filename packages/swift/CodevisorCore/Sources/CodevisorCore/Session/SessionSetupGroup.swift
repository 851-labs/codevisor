import Foundation

public enum SessionSetupGroup: Equatable, Identifiable, Sendable {
  case phase(SessionSetupPhase)
  case sandbox(SandboxStartSummary)

  public var id: String {
    switch self {
    case let .phase(phase): phase.id
    case .sandbox: "sandbox-start"
    }
  }

  public static func grouping(_ phases: [SessionSetupPhase]) -> [SessionSetupGroup] {
    let sandboxSteps = phases.filter(isSandboxStep)
    guard let summary = SandboxStartSummary(steps: sandboxSteps) else { return phases.map(Self.phase) }

    let others = phases.filter { !isSandboxStep($0) }.map(Self.phase)
    return [.sandbox(summary)] + others
  }

  private static func isSandboxStep(_ phase: SessionSetupPhase) -> Bool {
    phase.id.hasPrefix(SandboxSetupSteps.phaseIdPrefix)
  }
}
