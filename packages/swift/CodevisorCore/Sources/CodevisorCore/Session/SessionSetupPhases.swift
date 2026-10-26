import Foundation

enum SessionSetupPhases {
  static func merging(live: [SessionSetupPhase], persisted: [SessionSetupPhase]) -> [SessionSetupPhase] {
    live + persisted.filter { phase in !live.contains { covers($0, phase) } }
  }

  private static let coveringPrefixes = [
    SessionSetupPhase.worktreePhaseId: "worktree.setup:",
    EphemeralSetupSteps.phaseId(.clone): "project.setup:",
  ]

  private static func covers(_ live: SessionSetupPhase, _ persisted: SessionSetupPhase) -> Bool {
    guard live.id != persisted.id else { return true }
    guard let prefix = coveringPrefixes[live.id] else { return false }
    return persisted.id.hasPrefix(prefix)
  }
}
