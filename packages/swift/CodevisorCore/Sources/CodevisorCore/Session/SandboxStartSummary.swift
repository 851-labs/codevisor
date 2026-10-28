import Foundation

public struct SandboxStartSummary: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case running, succeeded, failed
  }

  public let steps: [SessionSetupPhase]

  public init?(steps: [SessionSetupPhase]) {
    guard !steps.isEmpty else { return nil }
    self.steps = steps
  }

  public var state: State {
    if steps.contains(where: { $0.failureMessage != nil }) { return .failed }
    if steps.allSatisfy(\.isSucceeded) { return .succeeded }
    return .running
  }

  public var shownSteps: [SessionSetupPhase] { steps.filter { !$0.isPending } }

  public var log: String {
    shownSteps.flatMap(Self.logLines).joined(separator: "\n")
  }

  public var startedAt: Date {
    (steps.first { !$0.isPending } ?? steps[0]).startedAt
  }

  public var duration: TimeInterval? {
    guard state != .running, let end = steps.compactMap(\.endedAt).max() else { return nil }
    return end.timeIntervalSince(startedAt)
  }

  private static func logLines(_ step: SessionSetupPhase) -> [String] {
    var lines = ["==> \(step.activeTitle)"] + step.logs.map(\.text)
    if let failure = step.failureMessage, lines.last != failure { lines.append(failure) }
    return lines
  }

  public var title: String {
    switch state {
    case .running: "Starting sandbox"
    case .succeeded: SetupDuration.completed("Started sandbox", after: duration)
    case .failed: SetupDuration.stopped("Sandbox failed", after: duration)
    }
  }
}
