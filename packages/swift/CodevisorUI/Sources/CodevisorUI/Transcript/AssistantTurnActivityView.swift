import ACPKit
import CodevisorCore
import SwiftUI

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

public struct AssistantTurnActivitySlot: View {
  public let activity: AssistantTurnActivity?
  public let waitingSince: Date?

  public init(_ activity: AssistantTurnActivity?, turn: AssistantTurn? = nil) {
    self.activity = activity
    self.waitingSince = turn?.harnessWaitStartedAt
  }

  public var body: some View {
    Group {
      if let activity {
        AssistantTurnActivityView(activity)
      } else if let waitingSince {
        TranscriptStartingWorkedHeader(startedAt: waitingSince)
          .suppressedDuringStreamingTextEntrance()
      } else {
        Text("Thinking…")
          .font(.callout)
          .hidden()
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: TranscriptWorkedSectionHeaderView.lineHeight)
  }
}

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

  nonisolated static func merging(_ shown: [ToolCall], _ waiting: [ToolCall]) -> [ToolCall] {
    let current = Dictionary(waiting.map { ($0.toolCallId, $0) }, uniquingKeysWith: { first, _ in first })
    let kept = shown.map { current[$0.toolCallId] ?? $0 }
    let keptIds = Set(kept.map(\.toolCallId))
    return kept + waiting.filter { !keptIds.contains($0.toolCallId) }
  }
}

extension AssistantTurn {
  public var harnessWaitStartedAt: Date? {
    guard isGenerating, !isThinking, !hasProviderContent else { return nil }
    return startedAt ?? Date()
  }
}
