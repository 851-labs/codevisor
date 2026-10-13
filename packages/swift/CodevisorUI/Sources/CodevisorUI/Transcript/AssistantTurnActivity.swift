import ACPKit
import CodevisorCore
import SwiftUI

/// Exactly one ephemeral label owns a turn. Session recovery/update status
/// is rendered by the transcript itself and takes precedence over turn work.
public struct AssistantTurnActivity: Equatable {
  public let message: String
  public let followsResponse: Bool
  /// The finished turn waits on background work, shown as its subagents'
  /// chips where they can be found.
  public var waitingOn: String?

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
    // An agent call being written has no chip yet: this line stands in for
    // it until its input arrives, even beside other running work.
    if turn.isStartingSubagent {
      return Self(message: "Starting agent…", followsResponse: false)
    }
    guard turn.showsActivityIndicator, turn.isThinking else { return nil }
    return Self(message: "Thinking…", followsResponse: false)
  }
}

public struct AssistantTurnActivityView: View {
  public let activity: AssistantTurnActivity

  public init(_ activity: AssistantTurnActivity) { self.activity = activity }

  public var body: some View {
    Group {
      if let waitingOn = activity.waitingOn {
        WaitingOnAgentsLine(description: waitingOn)
      } else {
        ShimmeringText(text: activity.message)
      }
    }
    .suppressedDuringStreamingTextEntrance()
  }
}

/// The activity row's place while no label is showing. Before the
/// harness's first event it times the wait, as the turn's worked header
/// will; otherwise the turn keeps `reservesActivitySlot` across tool calls,
/// so the row renders invisibly at the label's exact height instead of
/// collapsing and bouncing the transcript each time a tool starts or
/// finishes.
public struct AssistantTurnActivitySlot: View {
  public let activity: AssistantTurnActivity?
  public let waitingSince: Date?

  public init(_ activity: AssistantTurnActivity?, turn: AssistantTurn? = nil) {
    self.activity = activity
    self.waitingSince = turn?.harnessWaitStartedAt
  }

  public var body: some View {
    if let activity {
      AssistantTurnActivityView(activity)
    } else if let waitingSince {
      TranscriptStartingWorkedHeader(startedAt: waitingSince)
        .suppressedDuringStreamingTextEntrance()
    } else {
      // Plain text in the shimmer's font: same line height, no animation.
      Text("Thinking…")
        .font(.callout)
        .hidden()
        .accessibilityHidden(true)
    }
  }
}

/// A chip for each subagent the finished turn waits on, shimmering while it
/// runs; a chip opens its agent's thread. Chips stay put as their agents finish,
/// so the line never reflows under the pointer, until it goes away with the
/// wait. Falls back to the task's description when no spawning call is in
/// the transcript.
public struct WaitingOnAgentsLine: View {
  let description: String
  @Environment(\.transcriptController) private var controller
  @State private var shown: [ToolCall] = []

  public init(description: String) { self.description = description }

  public var body: some View {
    let calls = Self.merging(shown, controller?.waitingSubagentCalls ?? [])
    Group {
      if calls.isEmpty {
        ShimmeringText(text: "Waiting on \(description)...")
      } else {
        SubagentChips(calls: calls, isTurnActive: false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: calls.map(\.toolCallId), initial: true) { shown = calls }
  }

  /// `shown` in place, refreshed from `waiting`, with newly waited-on calls
  /// after them.
  nonisolated static func merging(_ shown: [ToolCall], _ waiting: [ToolCall]) -> [ToolCall] {
    let current = Dictionary(waiting.map { ($0.toolCallId, $0) }, uniquingKeysWith: { first, _ in first })
    let kept = shown.map { current[$0.toolCallId] ?? $0 }
    let keptIds = Set(kept.map(\.toolCallId))
    return kept + waiting.filter { !keptIds.contains($0.toolCallId) }
  }
}

extension AssistantTurn {
  /// When a live turn that has heard nothing from its harness yet started.
  public var harnessWaitStartedAt: Date? {
    guard isGenerating, !isThinking, !hasProviderContent else { return nil }
    return startedAt ?? Date()
  }
}
