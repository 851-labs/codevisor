import CodevisorProtocol
import Foundation

enum TranscriptBotRowAssembly {
  static let timestampGap: TimeInterval = 15 * 60
  static let groupedSpacing: CGFloat = 2
  static let groupTailSpacing: CGFloat = 12

  static func assemble(
    _ conversation: TranscriptBotConversation,
    input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions
  ) throws -> [TranscriptPresentationRow] {
    let messages = conversation.messages
    var rows: [TranscriptPresentationRow] = []
    rows.reserveCapacity(messages.count + 4)
    var previous: TranscriptBotMessage?
    for (index, message) in messages.enumerated() {
      if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
      if let sentAt = message.sentAt, startsNewMoment(sentAt, after: previous) {
        rows.append(
          .init(
            id: .botTimestamp(message.id),
            content: .botTimestamp(sentAt),
            estimatedHeight: 28
          ))
      }
      let next = messages.indices.contains(index + 1) ? messages[index + 1] : nil
      let isGroupTail = next.map { !continuesGroup($0, after: message) } ?? true
      rows.append(row(for: message, isGroupTail: isGroupTail))
      previous = message
    }
    if let pending = pendingMessage(input, conversation: conversation) {
      rows.append(
        .init(
          id: .message(pending.id),
          content: .optimistic(pending),
          estimatedHeight: 44,
          measurementRevision: TranscriptMessageRowMetrics.optimisticMeasurementRevision(for: pending),
          spacingAfter: groupTailSpacing
        ))
    }
    if conversation.isWorking {
      rows.append(.init(id: .botTyping, content: .botTyping, estimatedHeight: 38))
    }
    if let message = input.activityMessage {
      rows.append(
        .init(
          id: .connecting, content: .connecting(message), estimatedHeight: 32,
          measurementRevision: message.hashValue))
    }
    if case let .failed(message) = input.status {
      rows.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
    }
    if let requestedHeight = options.bottomSpacerHeight {
      let height = max(1, requestedHeight)
      rows.append(.init(id: .bottomSpacer, content: .bottomSpacer(height), estimatedHeight: height))
    }
    return rows
  }

  private static func row(for message: TranscriptBotMessage, isGroupTail: Bool) -> TranscriptPresentationRow {
    let spacing = isGroupTail ? groupTailSpacing : groupedSpacing
    if message.sender == .user, let id = UUID(uuidString: message.id) {
      let user = UserMessage(id: id, text: message.text, attachments: message.attachments)
      return .init(
        id: .message(id),
        content: .message(.user(user), waitingOnBackgroundTask: nil),
        estimatedHeight: estimatedHeight(for: message),
        measurementRevision: TranscriptMessageRowMetrics.optimisticMeasurementRevision(for: user),
        spacingAfter: spacing
      )
    }
    return .init(
      id: .botMessage(message.id),
      content: .botMessage(message, isGroupTail: isGroupTail),
      estimatedHeight: estimatedHeight(for: message),
      measurementRevision: message.text.hashValue ^ message.attachments.count,
      spacingAfter: spacing
    )
  }

  private static func pendingMessage(
    _ input: TranscriptProjectionInput,
    conversation: TranscriptBotConversation
  ) -> UserMessage? {
    guard let pending = input.pendingUserMessage else { return nil }
    let id = pending.id.uuidString.lowercased()
    return conversation.messages.contains { $0.id.lowercased() == id } ? nil : pending
  }

  private static func startsNewMoment(_ sentAt: Date, after previous: TranscriptBotMessage?) -> Bool {
    guard let previous else { return true }
    guard let previousAt = previous.sentAt else { return false }
    return sentAt.timeIntervalSince(previousAt) > timestampGap
  }

  private static func continuesGroup(_ next: TranscriptBotMessage, after message: TranscriptBotMessage) -> Bool {
    guard next.sender == message.sender, message.sender != .notice else { return false }
    guard let nextAt = next.sentAt, let sentAt = message.sentAt else { return true }
    return nextAt.timeIntervalSince(sentAt) <= timestampGap
  }

  private static func estimatedHeight(for message: TranscriptBotMessage) -> CGFloat {
    let lines = max(1, message.text.count / 70 + message.text.filter { $0 == "\n" }.count + 1)
    let attachments: CGFloat = message.attachments.isEmpty ? 0 : 140
    return CGFloat(lines) * 20 + 20 + attachments
  }
}
