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

  public var startedAt: Date {
    (steps.first { !$0.isPending } ?? steps[0]).startedAt
  }

  public var duration: TimeInterval? {
    guard state == .succeeded, let end = steps.compactMap(\.endedAt).max() else { return nil }
    return end.timeIntervalSince(startedAt)
  }

  public var currentStep: SessionSetupPhase? { steps.first(where: \.isRunning) }

  public var title: String {
    switch state {
    case .running: "Starting sandbox"
    case .succeeded: SetupDuration.completed("Started sandbox", after: duration)
    case .failed: "Couldn't start sandbox"
    }
  }
}
