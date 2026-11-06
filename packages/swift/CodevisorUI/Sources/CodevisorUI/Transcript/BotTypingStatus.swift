import ACPKit
import TranscriptKit

enum BotTypingStatus: Equatable {
  case thinking
  case typing
  case callingAgent
  case step(String)

  private static let callingLabel = "Talking to an agent…"

  init(activity: WorkedSectionActivity) {
    switch activity {
    case .step("Thinking"), .pending, .starting: self = .thinking
    case .step(Self.callingLabel): self = .callingAgent
    case let .step(label): self = .step(label)
    case .answering, .writing: self = .typing
    }
  }

  static func activity(of turn: AssistantTurn?) -> WorkedSectionActivity {
    guard let turn else { return .starting }
    if turn.toolCalls.contains(where: { !$0.isSettled && $0.sendsBotMessage }) { return .writing }
    if turn.toolCalls.contains(where: { !$0.isSettled && $0.talksToAgent }) { return .step(callingLabel) }
    return turn.workedSectionActivity
  }

  var text: String {
    switch self {
    case .thinking: "Thinking…"
    case .typing: "Typing…"
    case .callingAgent: Self.callingLabel
    case let .step(label): label
    }
  }
}

extension ToolCall {
  fileprivate static let agentPaths = [
    "agents.start", "agents.message", "agents.answer", "agents.status", "agents.wait",
    "agents.debug.search", "agents.debug.item", "agents.debug.queue", "agents.debug.state", "agents.debug.update",
  ]

  fileprivate var sendsBotMessage: Bool {
    calls(["messages.send"])
  }

  fileprivate var talksToAgent: Bool {
    calls(Self.agentPaths)
  }

  private func calls(_ paths: [String]) -> Bool {
    if codevisorExecution?.calls.contains(where: { call in paths.contains { call.path.hasSuffix($0) } }) == true {
      return true
    }
    let code = rawInput?["code"]?.stringValue ?? ""
    return codevisorGatewayOperation == .execute && paths.contains { code.contains($0) }
  }
}
