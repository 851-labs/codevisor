import Foundation

@MainActor
final class FirstLaunchAnalytics {
  enum Ending: String {
    case gotStarted = "got_started"
    case handedOff = "handed_off"
    case notNewInstall = "not_new_install"
  }

  private let now: () -> Date
  private var startedAt: Date?
  private var stepStartedAt: [FirstLaunchStep: Date] = [:]
  private var hasEnded = false

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  func started() {
    startedAt = now()
    Analytics.capture(.firstLaunchStarted)
  }

  func stepStarted(_ step: FirstLaunchStep) {
    stepStartedAt[step] = now()
  }

  func stepFinished(_ step: FirstLaunchStep, outcome: FirstLaunchStepOutcome, found: Int) {
    Analytics.capture(
      .firstLaunchStep,
      properties: [
        "step": .string(Self.name(of: step)),
        "outcome": .string(outcome == .done ? "done" : "skipped"),
        "found_count": .integer(found),
        "duration_ms": .integer(milliseconds(since: stepStartedAt[step])),
      ])
  }

  func ended(_ ending: Ending) {
    guard !hasEnded else { return }
    hasEnded = true
    Analytics.capture(
      .firstLaunchFinished,
      properties: [
        "outcome": .string(ending.rawValue),
        "duration_ms": .integer(milliseconds(since: startedAt)),
      ])
  }

  private func milliseconds(since start: Date?) -> Int {
    guard let start else { return 0 }
    return Int((now().timeIntervalSince(start) * 1_000).rounded())
  }

  private static func name(of step: FirstLaunchStep) -> String {
    switch step {
    case .harnesses: "harnesses"
    case .projects: "projects"
    case .models: "models"
    }
  }
}
