public enum TranscriptEventKind: Sendable, Equatable, CaseIterable {
  case plugin
  case threadMessage
  case agentMessage
  case agentTurnEnded
  case agentWaitingForUser
  case agentErrored
  case jobFinished
  case backgroundTaskFinished
  case restarted
  case usageLimitReset
  case questionAnswered
  case botCreated
  case bookkeeping

  init(type: String) {
    self = Self.byType[type] ?? .bookkeeping
  }

  var isAgentStatus: Bool {
    switch self {
    case .agentTurnEnded, .agentWaitingForUser, .agentErrored: true
    default: false
    }
  }

  public var showsInBotConversation: Bool {
    self != .bookkeeping && !isAgentStatus
  }

  private static let byType: [String: TranscriptEventKind] = [
    "plugin.event": .plugin,
    TranscriptEvent.threadMessageType: .threadMessage,
    TranscriptEvent.agentMessageType: .agentMessage,
    "session.turn_ended": .agentTurnEnded,
    "session.waiting_for_user": .agentWaitingForUser,
    "session.errored": .agentErrored,
    "execution.job_finished": .jobFinished,
    "exec.task_finished": .backgroundTaskFinished,
    "harness.task_finished": .backgroundTaskFinished,
    "session.restarted": .restarted,
    "session.usage_limit_reset": .usageLimitReset,
    "question.answered": .questionAnswered,
    "bot.created": .botCreated,
  ]
}
