import Foundation

public enum TranscriptAutoResumeStamp {
  public static func stamping(
    _ autoResume: SessionAutoResume?,
    onto item: ConversationItem?
  ) -> ConversationItem? {
    guard let autoResume, case var .assistant(message)? = item,
      message.turn.stopKind == usageLimitStopKind
    else { return item }
    message.turn.autoResume = autoResume
    return .assistant(message)
  }

  public static func stamping(
    _ autoResume: SessionAutoResume?,
    onto conversation: [ConversationItem]
  ) -> [ConversationItem] {
    guard autoResume != nil, let index = latestAssistantIndex(in: conversation) else {
      return conversation
    }
    var stamped = conversation
    stamped[index] = stamping(autoResume, onto: conversation[index]) ?? conversation[index]
    return stamped
  }

  private static let usageLimitStopKind = "usageLimit"

  private static func latestAssistantIndex(in conversation: [ConversationItem]) -> Int? {
    conversation.lastIndex {
      if case .assistant = $0 { return true }
      return false
    }
  }
}
