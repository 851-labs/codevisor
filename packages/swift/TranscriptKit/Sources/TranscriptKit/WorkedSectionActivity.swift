import ACPKit
import Foundation

public enum WorkedSectionActivity: Equatable, Sendable {
  case step(String)
  case answering
  case writing
  case pending
  case starting

  public static func waitingLabel(for agents: [ToolCall]) -> String {
    let names = agents.map(\.agentName)
    switch names.count {
    case 1: return "Waiting for \(names[0])"
    case 2: return "Waiting for \(names[0]) and \(names[1])"
    default: return "Waiting for \(names.count) agents"
    }
  }
}

extension AssistantTurn {
  public var workedSectionActivity: WorkedSectionActivity {
    var label: String
    if let activity = AssistantTurnActivity.resolve(
      turn: self, isWaitingOnUser: false, sessionActivity: nil, backgroundTask: nil,
      goalActivity: nil),
      !activity.followsResponse
    {
      label = activity.message
    } else if case let awaited = awaitedAgentCalls, !awaited.isEmpty {
      label = WorkedSectionActivity.waitingLabel(for: awaited)
    } else if let running = toolCalls.last(where: { !$0.isSettled && !isUnstartedSubagent($0) }) {
      label = running.displayTitle
      guard running.rawInput != nil || label.contains(" ") else { return .pending }
    } else if finalText == nil {
      guard hasProviderContent else { return .starting }
      label = "Thinking"
    } else {
      return finalTextIsAsserted ? .answering : .writing
    }
    while let last = label.last, last == "…" || last == "." {
      label.removeLast()
    }
    return .step(label)
  }
}
