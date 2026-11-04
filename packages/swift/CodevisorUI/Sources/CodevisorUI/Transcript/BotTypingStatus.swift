import ACPKit
import TranscriptKit

enum BotTypingStatus: Equatable {
  case thinking
  case typing
  case step(String)

  init(activity: WorkedSectionActivity) {
    switch activity {
    case .step("Thinking"), .pending, .starting: self = .thinking
    case let .step(label): self = .step(label)
    case .answering, .writing: self = .typing
    }
  }

  static func activity(of turn: AssistantTurn?) -> WorkedSectionActivity {
    guard let turn else { return .starting }
    if turn.toolCalls.contains(where: { !$0.isSettled && $0.sendsBotMessage }) { return .writing }
    return turn.workedSectionActivity
  }

  var text: String {
    switch self {
    case .thinking: "Thinking…"
    case .typing: "Typing…"
    case let .step(label): label
    }
  }

  var motion: BotMascotMotion {
    self == .thinking ? .idle : .working
  }
}

extension ToolCall {
  fileprivate var sendsBotMessage: Bool {
    let sendPath = "messages.send"
    if codevisorExecution?.calls.contains(where: { $0.path.hasSuffix(sendPath) }) == true { return true }
    return codevisorGatewayOperation == .execute && rawInput?["code"]?.stringValue?.contains(sendPath) == true
  }
}
