import ACPKit
import CodevisorCore
import SwiftUI

/// Exactly one ephemeral label owns a turn. Session recovery/update status
/// is rendered by the transcript itself and takes precedence over turn work.
public struct AssistantTurnActivity: Equatable {
  public let message: String
  public let followsResponse: Bool

  /// Shown from the moment a prompt is committed until the provider's first
  /// event. The optimistic first-send placeholder uses the same words so the
  /// handoff into the live turn is invisible.
  public static let waitingOnHarnessMessage = "Waiting on harness..."

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
    return Self(message: turn.isThinking ? "Thinking…" : waitingOnHarnessMessage, followsResponse: false)
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
