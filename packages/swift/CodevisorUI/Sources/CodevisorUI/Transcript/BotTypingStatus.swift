import ACPKit
import TranscriptKit

enum BotTypingStatus: Equatable {
  case thinking
  case typing
  case sent
  case step(String)

  init(turn: AssistantTurn?) {
    guard let turn else {
      self = .thinking
      return
    }
    if turn.toolCalls.contains(where: { !$0.isSettled && $0.sendsBotMessage }) {
      self = .typing
      return
    }
    switch turn.workedSectionActivity {
    case let .step(label): self = .step(label)
    case .answering, .writing: self = .typing
    case .pending, .starting: self = .thinking
    }
    if self == .step("Thinking") {
      self = turn.toolCalls.last?.sendsBotMessage == true ? .sent : .thinking
    }
  }

  var text: String {
    switch self {
    case .thinking: "Thinking…"
    case .typing, .sent: "Typing…"
    case let .step(label): label
    }
  }

  var motion: BotMascotMotion {
    self == .thinking ? .idle : .working
  }

  func isShown(afterReply: Bool) -> Bool {
    switch self {
    case .thinking, .sent: !afterReply
    case .typing, .step: true
    }
  }
}

extension ToolCall {
  fileprivate var sendsBotMessage: Bool {
    let sendPath = "messages.send"
    if codevisorExecution?.calls.contains(where: { $0.path.hasSuffix(sendPath) }) == true { return true }
    return codevisorGatewayOperation == .execute && rawInput?["code"]?.stringValue?.contains(sendPath) == true
  }
}
