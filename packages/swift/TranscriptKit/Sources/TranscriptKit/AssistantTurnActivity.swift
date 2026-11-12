import ACPKit
import Foundation

public struct AssistantTurnActivity: Equatable, Sendable {
  public let message: String
  public let followsResponse: Bool
  public var waitingOn: String?

  public init(message: String, followsResponse: Bool, waitingOn: String? = nil) {
    self.message = message
    self.followsResponse = followsResponse
    self.waitingOn = waitingOn
  }

  public static func resolve(
    turn: AssistantTurn,
    isWaitingOnUser: Bool,
    sessionActivity: String?,
    backgroundTask: String?,
    goalActivity: GoalActivity?
  ) -> Self? {
    guard sessionActivity == nil, !isWaitingOnUser else { return nil }
    if turn.isGenerating, let retry = turn.retryStatus {
      let suffix = retry.attempt.flatMap { attempt in retry.of.map { " \(attempt)/\($0)" } } ?? ""
      return Self(message: retry.message + suffix, followsResponse: false)
    }
    if turn.isGenerating, turn.contextCompactionStatus == .started {
      return Self(message: "Compacting context…", followsResponse: false)
    }
    if turn.finalText != nil {
      if let goalActivity {
        return Self(message: goalActivity == .planning ? "Planning…" : "Verifying…", followsResponse: true)
      }
      if let backgroundTask {
        return Self(message: "Waiting on \(backgroundTask)...", followsResponse: true, waitingOn: backgroundTask)
      }
    }
    if turn.isStartingSubagent {
      return Self(message: "Starting agent…", followsResponse: false)
    }
    guard turn.showsActivityIndicator, turn.isThinking else { return nil }
    return Self(message: "Thinking…", followsResponse: false)
  }
}
