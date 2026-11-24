import CodevisorProtocol
import Foundation

enum TranscriptBotRowAssembly {
  static let timestampGap: TimeInterval = 15 * 60
  static let groupedSpacing: CGFloat = 2
  static let groupTailSpacing: CGFloat = 12

  static func assemble(
    _ conversation: TranscriptBotConversation,
    input: TranscriptProjectionInput
  ) throws -> [TranscriptPresentationRow] {
    let stoppedTurn = stoppedLatestTurn(in: input)
    let messages = withoutStopNotice(conversation.messages, for: stoppedTurn)
      .flatMap(TranscriptBotMessageParts.parts(of:))
    var rows: [TranscriptPresentationRow] = []
    rows.reserveCapacity(messages.count + 4)
    var previous: TranscriptBotMessage?
    var timedRows = TranscriptBotTimedRows.entries(in: input, spacingAfter: groupTailSpacing)[...]
    let placements = placementTimes(of: messages)
    for (index, message) in messages.enumerated() {
      if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
      let followsTimedRow = appendTimedRows(askedBefore: placements[index], from: &timedRows, to: &rows)
      if let sentAt = message.moment, startsNewMoment(sentAt, after: previous) {
        rows.append(
          .init(
            id: .botTimestamp(message.id),
            content: .botTimestamp(sentAt),
            estimatedHeight: 28
          ))
      }
      appendAuthorName(heading: message, after: followsTimedRow ? nil : previous, to: &rows)
      let isGroupTail = endsGroup(at: index, of: messages, placements: placements, before: timedRows)
      if let delivery = message.delivery, message.sender == .user, let id = UUID(uuidString: message.id) {
        rows.append(row(for: message, isGroupTail: isGroupTail, spacingAfter: TranscriptPresentationRow.deliveryGap))
        rows.append(
          .delivery(
            id, delivery, spacingAfter: isGroupTail ? groupTailSpacing : groupedSpacing + 4))
      } else {
        rows.append(
          row(for: message, isGroupTail: isGroupTail, spacingAfter: isGroupTail ? groupTailSpacing : groupedSpacing))
      }
      previous = message
    }
    appendTimedRows(askedBefore: .distantFuture, from: &timedRows, to: &rows)
    appendPendingMessage(input, conversation: conversation, to: &rows)
    for entry in timedRows { TranscriptThreadEventRows.append(entry.row, to: &rows) }
    if let stoppedTurn {
      TranscriptAssistantRowProjection.appendStopDetail(stoppedTurn, to: &rows)
    }
    if conversation.isWorking { rows.append(.init(id: .botTyping, content: .botTyping, estimatedHeight: 38)) }
    TranscriptRowAssembly.appendActivityAndErrors(input, to: &rows)
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
    guard stoppedTurn != nil else { return messages }
    let kept = messages.lastIndex { $0.sender != .notice }.map { $0 + 1 } ?? 0
    return Array(messages[..<kept])
  }

  private static func placementTimes(of messages: [TranscriptBotMessage]) -> [Date] {
    var later = Date.distantFuture
    let reversed = messages.reversed().map { message in
      later = message.sentAt ?? later
      return later
    }
    return reversed.reversed()
  }

  @discardableResult
  private static func appendTimedRows(
    askedBefore placement: Date,
    from timedRows: inout ArraySlice<TranscriptBotTimedRows.Entry>,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    var appended = false
    while let next = timedRows.first, let askedAt = next.askedAt, askedAt < placement {
      TranscriptThreadEventRows.append(next.row, to: &rows)
      timedRows.removeFirst()
      appended = true
    }
    return appended
  }

  private static func endsGroup(
    at index: Int, of messages: [TranscriptBotMessage], placements: [Date],
    before timedRows: ArraySlice<TranscriptBotTimedRows.Entry>
  ) -> Bool {
    let nextIndex = index + 1
    guard messages.indices.contains(nextIndex) else { return true }
    guard continuesGroup(messages[nextIndex], after: messages[index]) else { return true }
    guard let askedAt = timedRows.first?.askedAt else { return false }
    return askedAt < placements[nextIndex]
  }

  private static func row(
    for message: TranscriptBotMessage, isGroupTail: Bool, spacingAfter spacing: CGFloat
  ) -> TranscriptPresentationRow {
    if message.sender == .user, let id = UUID(uuidString: message.id) {
      let user = UserMessage(id: id, text: message.text, attachments: message.attachments).presentingQuotes
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
      measurementRevision: message.text.hashValue ^ message.attachments.count ^ message.files.map(\.id).hashValue
        ^ (message.app?.viewId.hashValue ?? 0),
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
        content: .optimistic(pending.presentingQuotes),
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

  private static func appendAuthorName(
    heading message: TranscriptBotMessage, after previous: TranscriptBotMessage?,
    to rows: inout [TranscriptPresentationRow]
  ) {
    guard let name = message.author?.name, !name.isEmpty else { return }
    if let previous, continuesGroup(message, after: previous) { return }
    rows.append(
      .init(
        id: .botAuthorName(message.id),
        content: .botAuthorName(name),
        estimatedHeight: 18,
        spacingAfter: groupedSpacing
      ))
  }

  private static func startsNewMoment(_ sentAt: Date, after previous: TranscriptBotMessage?) -> Bool {
    guard let previous else { return true }
    guard let previousAt = previous.moment else { return false }
    return sentAt.timeIntervalSince(previousAt) > timestampGap
  }

  private static func continuesGroup(_ next: TranscriptBotMessage, after message: TranscriptBotMessage) -> Bool {
    guard next.sender == message.sender, next.author == message.author, message.sender != .notice else {
      return false
    }
    guard let nextAt = next.moment, let sentAt = message.moment else { return true }
    return nextAt.timeIntervalSince(sentAt) <= timestampGap
  }

  private static func estimatedHeight(for message: TranscriptBotMessage) -> CGFloat {
    if message.app != nil { return TranscriptPluginAppRowProjection.appEstimatedHeight }
    let lines = max(1, message.text.count / 70 + message.text.filter { $0 == "\n" }.count + 1)
    let attachments: CGFloat = message.attachments.isEmpty && message.files.isEmpty ? 0 : 140
    return CGFloat(lines) * 20 + 20 + attachments
  }
}
