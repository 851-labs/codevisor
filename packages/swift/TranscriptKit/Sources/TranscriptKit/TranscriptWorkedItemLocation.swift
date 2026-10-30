import Foundation

public struct TranscriptWorkedItemLocation: Sendable, Equatable {
  public let reference: TranscriptWorkedItemReference
  public let isEarlierHistory: Bool
  public let toolGroupID: String?

  public var section: TranscriptWorkedSectionIdentity {
    TranscriptWorkedSectionIdentity(messageID: reference.messageID, kind: reference.section)
  }

  public init(reference: TranscriptWorkedItemReference, isEarlierHistory: Bool, toolGroupID: String?) {
    self.reference = reference
    self.isEarlierHistory = isEarlierHistory
    self.toolGroupID = toolGroupID
  }

  public static func of(toolCall toolCallId: String, in conversation: [ConversationItem]) -> Self? {
    for case let .assistant(message) in conversation.reversed() {
      if let location = of(toolCall: toolCallId, in: message) { return location }
    }
    return nil
  }

  private static func of(toolCall toolCallId: String, in message: AssistantMessage) -> Self? {
    let sections: [(TranscriptWorkedSectionKind, [WorkedItem])] = [
      (.planning, message.turn.workedItemsBeforePlan),
      (.implementation, message.turn.workedItemsAfterPlan),
    ]
    for (kind, items) in sections {
      guard let index = items.firstIndex(where: { $0.contains(toolCall: toolCallId) }) else { continue }
      return location(of: items[index], at: index, in: items, message: message, kind: kind)
    }
    return nil
  }

  private static func location(
    of item: WorkedItem, at index: Int, in items: [WorkedItem], message: AssistantMessage,
    kind: TranscriptWorkedSectionKind
  ) -> Self {
    Self(
      reference: TranscriptWorkedItemReference(messageID: message.id, section: kind, itemID: item.id),
      isEarlierHistory: index < items.earlierHistoryCount,
      toolGroupID: item.toolGroupID
    )
  }
}

extension WorkedItem {
  fileprivate func contains(toolCall toolCallId: String) -> Bool {
    switch self {
    case .text: false
    case let .toolGroup(group): group.calls.contains { $0.toolCallId == toolCallId }
    case let .subagents(_, calls): calls.contains { $0.toolCallId == toolCallId }
    }
  }

  fileprivate var toolGroupID: String? {
    guard case let .toolGroup(group) = self else { return nil }
    return group.id
  }
}
