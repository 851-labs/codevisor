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
    let stoppedTurn = stoppedLatestTurn(in: input)
    let messages = withoutStopNotice(conversation.messages, for: stoppedTurn)
    var rows: [TranscriptPresentationRow] = []
    rows.reserveCapacity(messages.count + 4)
    var previous: TranscriptBotMessage?
    var setupBubbles = setupRequests(in: input)[...]
    for (index, message) in messages.enumerated() {
      if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
      while let next = setupBubbles.first, wasAsked(next.askedAt, before: message) {
        rows.append(.setupRequest(next.request, inBotConversation: true, spacingAfter: groupTailSpacing))
        setupBubbles.removeFirst()
      }
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
      if let delivery = message.delivery, message.sender == .user, let id = UUID(uuidString: message.id) {
        rows.append(row(for: message, isGroupTail: isGroupTail, spacingAfter: TranscriptPresentationRow.deliveryGap))
        rows.append(
          .delivery(id, delivery, spacingAfter: isGroupTail ? groupTailSpacing : groupedSpacing + 4))
      } else {
        rows.append(
          row(for: message, isGroupTail: isGroupTail, spacingAfter: isGroupTail ? groupTailSpacing : groupedSpacing))
      }
      previous = message
    }
    appendPendingMessage(input, conversation: conversation, to: &rows)
    for bubble in setupBubbles {
      rows.append(.setupRequest(bubble.request, inBotConversation: true, spacingAfter: groupTailSpacing))
    }
    if let stoppedTurn {
      TranscriptAssistantRowProjection.appendStopDetail(stoppedTurn, to: &rows)
    }
    if conversation.isWorking {
      rows.append(.init(id: .botTyping, content: .botTyping, estimatedHeight: 38))
    }
    TranscriptRowAssembly.appendActivityAndErrors(input, to: &rows)
    if let requestedHeight = options.bottomSpacerHeight {
      let height = max(1, requestedHeight)
      rows.append(.init(id: .bottomSpacer, content: .bottomSpacer(height), estimatedHeight: height))
    }
    return rows
  }

  private static func stoppedLatestTurn(in input: TranscriptProjectionInput) -> AssistantMessage? {
    let latest = input.activeItem ?? input.settledConversation.last(where: TranscriptAssistantRowProjection.isAssistant)
    guard case let .assistant(message)? = latest, !message.turn.isGenerating, message.turn.stopDetail != nil else {
      return nil
    }
    return message
  }

  private static func withoutStopNotice(
    _ messages: [TranscriptBotMessage], for stoppedTurn: AssistantMessage?
  ) -> [TranscriptBotMessage] {
    guard let last = messages.last, last.sender == .notice, last.text == stoppedTurn?.turn.stopDetail else {
      return messages
    }
    return Array(messages.dropLast())
  }

  private static func wasAsked(_ askedAt: Date?, before message: TranscriptBotMessage) -> Bool {
    guard let askedAt, let sentAt = message.sentAt else { return false }
    return askedAt < sentAt
  }

  private static func setupRequests(
    in input: TranscriptProjectionInput
  ) -> [(askedAt: Date?, request: TranscriptSetupRequest)] {
    (input.settledConversation + [input.activeItem].compactMap(\.self)).flatMap {
      item -> [(askedAt: Date?, request: TranscriptSetupRequest)] in
      guard case let .assistant(message) = item else { return [] }
      return message.turn.setupRequests.map { (askedAt: message.turn.endedAt, request: $0) }
    }
  }

  private static func row(
    for message: TranscriptBotMessage, isGroupTail: Bool, spacingAfter spacing: CGFloat
  ) -> TranscriptPresentationRow {
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
      content: .botMessage(
        message, TranscriptBotMessageContentCache.shared.content(for: message), isGroupTail: isGroupTail),
      estimatedHeight: estimatedHeight(for: message),
      measurementRevision: message.text.hashValue ^ message.attachments.count,
      spacingAfter: spacing
    )
  }

  private static func appendPendingMessage(
    _ input: TranscriptProjectionInput,
    conversation: TranscriptBotConversation,
    to rows: inout [TranscriptPresentationRow]
  ) {
    guard let pending = pendingMessage(input, conversation: conversation) else { return }
    rows.append(
      .init(
        id: .message(pending.id),
        content: .optimistic(pending),
        estimatedHeight: 44,
        measurementRevision: TranscriptMessageRowMetrics.optimisticMeasurementRevision(for: pending),
        spacingAfter: groupTailSpacing
      ))
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
