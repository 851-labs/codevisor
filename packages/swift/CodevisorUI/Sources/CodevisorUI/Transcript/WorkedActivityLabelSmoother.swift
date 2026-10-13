import ACPKit
import Foundation
import TranscriptKit

/// What a live worked header names.
enum WorkedSectionActivity: Equatable {
  /// Something the turn is doing: thinking, retrying, a running tool.
  case step(String)
  /// Only the answer is streaming; the header reads "Worked for".
  case answering
  /// A tool is starting but has no real title yet ("Bash" before its
  /// command arrives). It never replaces what the header shows.
  case pending
  /// Nothing from the harness yet: the header just times the wait.
  case starting
}

extension AssistantTurn {
  /// The live worked header's subject: the turn's own status (retrying,
  /// compacting, starting an agent, thinking), else the latest running tool
  /// that has its title. The timer beside it already says the work is
  /// ongoing, so a label drops any trailing ellipsis.
  var workedSectionActivity: WorkedSectionActivity {
    var label: String
    if let activity = AssistantTurnActivity.resolve(
      turn: self, isWaitingOnUser: false, sessionActivity: nil, backgroundTask: nil,
      goalActivity: nil),
      !activity.followsResponse
    {
      label = activity.message
    } else if case let awaited = awaitedAgentCalls, !awaited.isEmpty {
      // Blocked on its agents, the turn is waiting rather than running a
      // call named "Agent: …".
      label = WorkedTimelineText.waiting(for: awaited)
    } else if let running = toolCalls.last(where: { !$0.isSettled && !isUnstartedSubagent($0) }) {
      label = running.displayTitle
      // Harnesses announce a tool by its bare name before its input (and
      // real title) arrives; that name isn't worth a frame in the header.
      guard running.rawInput != nil || label.contains(" ") else { return .pending }
    } else if finalText == nil {
      // Before the harness's first event the header just times the wait;
      // between tool calls the model is deciding what to do next.
      guard hasProviderContent else { return .starting }
      label = "Thinking"
    } else {
      return .answering
    }
    while let last = label.last, last == "…" || last == "." {
      label.removeLast()
    }
    return .step(label)
  }
}

/// Paces the live worked header so fast work doesn't flicker through every
/// step. A new subject shows once it has held for `settleInterval`, so a
/// Claude preamble retagged an instant later never flashes "Worked for";
/// while steps keep changing, the latest shows once the header has been out
/// of date for `refreshInterval`, so it still moves. A pending step never
/// replaces the label. Times are passed in, so the pacing is testable.
struct WorkedActivityLabelSmoother: Equatable {
  static let settleInterval: TimeInterval = 0.3
  static let refreshInterval: TimeInterval = 1.2

  /// What the header draws; nil until the first observation.
  private(set) var shown: WorkedSectionActivity?
  private var candidate: WorkedSectionActivity?
  private var candidateSince = Date.distantPast
  /// When the shown subject first fell behind the turn.
  private var staleSince: Date?

  /// The first subject shows at once; a tool still writing its input reads
  /// as the model deciding what to do.
  static func initial(_ activity: WorkedSectionActivity) -> WorkedSectionActivity {
    activity == .pending ? .step("Thinking") : activity
  }

  mutating func observe(_ next: WorkedSectionActivity, now: Date) {
    guard let shown else {
      shown = Self.initial(next)
      candidate = shown
      candidateSince = now
      return
    }
    if next != candidate {
      candidate = next
      candidateSince = now
    }
    if next == shown {
      staleSince = nil
    } else if next != .pending, staleSince == nil {
      staleSince = now
    }
    tick(now: now)
  }

  /// Re-evaluates without a new observation, at `deadline`. Comparing
  /// against the deadline itself (not an elapsed interval) guarantees a
  /// wake-up at the deadline changes the label instead of rescheduling.
  mutating func tick(now: Date) {
    guard let deadline, now >= deadline, let candidate else { return }
    shown = candidate
    staleSince = nil
  }

  /// When `tick` next changes the label; nil when nothing is waiting.
  var deadline: Date? {
    guard let candidate, candidate != .pending, candidate != shown else { return nil }
    let settle = candidateSince.addingTimeInterval(Self.settleInterval)
    guard let staleSince else { return settle }
    return min(settle, staleSince.addingTimeInterval(Self.refreshInterval))
  }
}
