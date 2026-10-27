import Foundation
import ACPKit

struct RemoteUserMessage {
  enum Match {
    case echo(index: Int, id: UUID)
    case optimistic(index: Int, user: UserMessage)
  }

  let id: String?
  let text: String
  let attachments: [Attachment]
  let isEvent: Bool
  let assistantItemId: UUID?
  let attribution: UserMessageAttribution?
  private let trimmedText: String

  init(
    id: String? = nil,
    text: String,
    attachments: [Attachment] = [],
    isEvent: Bool = false,
    assistantItemId: UUID? = nil,
    attribution: UserMessageAttribution? = nil
  ) {
    self.id = id
    self.text = text
    self.attachments = attachments
    self.isEvent = isEvent
    self.assistantItemId = assistantItemId
    self.attribution = attribution
    self.trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var echoId: UUID? {
    id.flatMap(UUID.init(uuidString:))
  }

  var hasContent: Bool {
    !trimmedText.isEmpty || !attachments.isEmpty
  }

  var userMessage: UserMessage {
    UserMessage(id: echoId ?? UUID(), text: text, attachments: attachments, isEvent: isEvent, attribution: attribution)
  }

  func match(in settled: [ConversationItem], pendingOptimisticIds: Set<UUID>) -> Match? {
    if let echo = echoMatch(in: settled) { return echo }
    guard !isEvent, attribution == nil else { return nil }

    return optimisticMatch(in: settled, pendingOptimisticIds: pendingOptimisticIds)
  }

  func mergingEcho(into user: UserMessage) -> UserMessage {
    var user = user
    if user.attachments.isEmpty { user.attachments = attachments }
    user.isEvent = user.isEvent || isEvent
    user.attribution = user.attribution ?? attribution
    return user
  }

  func fillingAttachments(of user: UserMessage) -> UserMessage? {
    guard user.attachments.isEmpty, !attachments.isEmpty else { return nil }

    var user = user
    user.attachments = attachments
    return user
  }

  private func echoMatch(in settled: [ConversationItem]) -> Match? {
    guard let echoId,
      let index = settled.lastIndex(where: { Self.isUser($0, id: echoId) })
    else { return nil }

    return .echo(index: index, id: echoId)
  }

  private func optimisticMatch(in settled: [ConversationItem], pendingOptimisticIds: Set<UUID>) -> Match? {
    guard let index = settled.lastIndex(where: { isOptimistic($0, pendingIds: pendingOptimisticIds) }),
      case let .user(user) = settled[index]
    else { return nil }

    return .optimistic(index: index, user: user)
  }

  private func isOptimistic(_ item: ConversationItem, pendingIds: Set<UUID>) -> Bool {
    guard case let .user(user) = item else { return false }
    return pendingIds.contains(user.id) && user.text == trimmedText
  }

  private static func isUser(_ item: ConversationItem, id: UUID) -> Bool {
    guard case let .user(user) = item else { return false }
    return user.id == id
  }
}
