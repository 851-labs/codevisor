import Foundation

enum SessionSetupPhases {
  static func merging(live: [SessionSetupPhase], persisted: [SessionSetupPhase]) -> [SessionSetupPhase] {
    live + persisted.filter { phase in !live.contains { covers($0, phase) } }
  }

  private static let coveringPrefixes = [
    SessionSetupPhase.worktreePhaseId: ["worktree.setup:", "project.setup:"],
    SandboxSetupSteps.phaseId(.clone): ["project.setup:"],
    SessionSetupPhase.projectSetupPhaseId: ["project.setup:"],
  ]

  private static func covers(_ live: SessionSetupPhase, _ persisted: SessionSetupPhase) -> Bool {
    guard live.id != persisted.id else { return true }
    guard let prefixes = coveringPrefixes[live.id] else { return false }
    return prefixes.contains { persisted.id.hasPrefix($0) }
  }
}
