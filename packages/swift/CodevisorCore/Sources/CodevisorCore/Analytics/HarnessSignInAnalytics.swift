import Foundation

@MainActor
public enum HarnessSignInAnalytics {
  public enum Outcome: String, Sendable {
    case succeeded
    case failed
    case cancelled
  }

  public static func started(harnessId: String, methodId: String?) {
    Analytics.capture(
      .harnessSignInStarted,
      properties: ["harness_id": .string(harnessId), "method_id": .string(methodId ?? "default")]
    )
  }

  public static func finished(harnessId: String, outcome: Outcome) {
    Analytics.capture(
      .harnessSignInFinished,
      properties: ["harness_id": .string(harnessId), "outcome": .string(outcome.rawValue)]
    )
  }
}
