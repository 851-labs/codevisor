import ACPKit
import CodevisorCore
import SwiftUI

/// Exactly one ephemeral label owns a turn. Session recovery/update status
/// is rendered by the transcript itself and takes precedence over turn work.
public struct AssistantTurnActivity: Equatable {
  public let message: String
  public let followsResponse: Bool

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
        return Self(message: "Waiting on \(backgroundTask)...", followsResponse: true)
      }
    }
    guard turn.showsActivityIndicator else { return nil }
    return Self(message: turn.isThinking ? "Thinking…" : "Waiting on harness...", followsResponse: false)
  }
}

public struct AssistantTurnActivityView: View {
  public let activity: AssistantTurnActivity

  public init(_ activity: AssistantTurnActivity) { self.activity = activity }

  public var body: some View {
    ShimmeringText(text: activity.message)
      .suppressedDuringStreamingTextEntrance()
  }
}
