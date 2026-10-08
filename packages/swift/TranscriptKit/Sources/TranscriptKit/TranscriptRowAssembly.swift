import CodevisorProtocol
import Foundation

/// Assembles row data in transcript order without retaining projection state.
enum TranscriptRowAssembly {
  static func assemble(
    _ input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions
  ) throws -> [TranscriptPresentationRow] {
    var rows: [TranscriptPresentationRow] = []
    rows.reserveCapacity(input.settledConversation.count + 6)
    let settled = input.settledConversation
    let hasSetup = !input.setupPhases.isEmpty && input.activityMessage == nil
    let pendingMessage = pendingMessageNotInHistory(input, settled: settled)
    let pendingIsOpeningRow = settled.isEmpty && !input.hasActiveItem
    let waitingDescription = input.activityMessage == nil ? input.waitingBackgroundTaskDescription : nil
    let waitingAssistantID = Self.waitingAssistantID(input, settled: settled, waitingDescription: waitingDescription)

    if settled.isEmpty, !input.hasActiveItem {
      appendOpeningRows(input, options: options, pendingMessage: pendingMessage, hasSetup: hasSetup, to: &rows)
    }

    // A failure is only actionable on the latest turn (retry, sign in,
    // switch account). Older turns' stop details are not presented at
    // all; a live active item makes every settled turn "older".
    let latestSettledAssistantID: UUID? =
      input.hasActiveItem
      ? nil
      : settled.last(where: TranscriptAssistantRowProjection.isAssistant)?.id

    try appendSettledRows(
      input, settled: settled, hasSetup: hasSetup, waitingDescription: waitingDescription,
      waitingAssistantID: waitingAssistantID, latestSettledAssistantID: latestSettledAssistantID, to: &rows
    )
    appendLiveAndPendingRows(
      input, settled: settled, hasSetup: hasSetup,
      pendingMessage: pendingMessage, pendingIsOpeningRow: pendingIsOpeningRow, to: &rows
    )
    appendWaitingRows(
      input, settled: settled, waitingDescription: waitingDescription, waitingAssistantID: waitingAssistantID, to: &rows
    )
    appendActivityAndErrors(input, to: &rows)
    appendBottomSpacer(options, to: &rows)
    return rows
  }

  private static func pendingMessageNotInHistory(
    _ input: TranscriptProjectionInput,
    settled: [ConversationItem]
  ) -> UserMessage? {
    return input.pendingUserMessage.flatMap { pending in
      settled.contains(where: { item in
        if case let .user(message) = item { return message.id == pending.id }
        return false
      }) ? nil : pending
    }
  }

  private static func waitingAssistantID(
    _ input: TranscriptProjectionInput,
    settled: [ConversationItem],
    waitingDescription: String?
  ) -> UUID? {
    guard !input.hasActiveItem,
      waitingDescription != nil,
      case let .assistant(message)? = settled.last,
      message.turn.finalText != nil
    else { return nil }
    return message.id
  }

  private static func appendOpeningRows(
    _ input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions,
    pendingMessage: UserMessage?,
    hasSetup: Bool,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if let message = pendingMessage {
      appendOptimisticMessage(message, to: &rows)
    }
    if hasSetup {
      appendSetupPhases(input.setupPhases, to: &rows)
    }
    if pendingMessage != nil, TranscriptRowProjectionCache.showsOptimisticAgentActivity(input) {
      rows.append(
        .init(
          id: .startingAgent,
          content: .startingAgent,
          estimatedHeight: TranscriptAssistantRowProjection.activityRowEstimatedHeight
        ))
    }
    appendInitialConnection(input, options: options, pendingMessage: pendingMessage, to: &rows)
  }

  private static func appendInitialConnection(
    _ input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions,
    pendingMessage: UserMessage?,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if !input.isLoadingInitialHistory, pendingMessage == nil, input.activityMessage == nil {
      if let message = input.serverWaitMessage {
        rows.append(
          .init(
            id: .serverWait,
            content: .serverWait(message),
            estimatedHeight: 32
          ))
      } else if options.includesConnectingRow,
        case let .connecting(message) = input.status
      {
        rows.append(
          .init(
            id: .connecting,
            content: .connecting(message),
            estimatedHeight: 32
          ))
      }
    }
  }

  private static func appendSettledRows(
    _ input: TranscriptProjectionInput,
    settled: [ConversationItem],
    hasSetup: Bool,
    waitingDescription: String?,
    waitingAssistantID: UUID?,
    latestSettledAssistantID: UUID?,
    to rows: inout [TranscriptPresentationRow]
  ) throws {
    for (index, item) in settled.enumerated() {
      if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
      if index == 0, hasSetup, TranscriptAssistantRowProjection.isAssistant(item) {
        appendSetupPhases(input.setupPhases, to: &rows)
      }
      TranscriptAssistantRowProjection.appendSettled(
        item,
        waitingOnBackgroundTask: item.id == waitingAssistantID
          ? waitingDescription
          : nil,
        presentsStopDetail: item.id == latestSettledAssistantID,
        to: &rows
      )
      if index == 0, hasSetup, TranscriptAssistantRowProjection.isUser(item) {
        appendSetupPhases(input.setupPhases, to: &rows)
      }
    }
  }

  private static func appendLiveAndPendingRows(
    _ input: TranscriptProjectionInput,
    settled: [ConversationItem],
    hasSetup: Bool,
    pendingMessage: UserMessage?,
    pendingIsOpeningRow: Bool,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if settled.isEmpty, input.hasActiveItem, hasSetup {
      appendSetupPhases(input.setupPhases, to: &rows)
    }
    if let activeItem = input.activeItem {
      rows.append(
        .init(
          id: .active(activeItem.id),
          content: .active(activeItem),
          estimatedHeight: TranscriptAssistantRowProjection.activeFallbackEstimatedHeight(
            for: activeItem
          )
        ))
    }
    if !pendingIsOpeningRow, let message = pendingMessage {
      appendOptimisticMessage(message, to: &rows)
    }
  }

  private static func appendWaitingRows(
    _ input: TranscriptProjectionInput,
    settled: [ConversationItem],
    waitingDescription: String?,
    waitingAssistantID: UUID?,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if let waitingDescription, waitingAssistantID == nil, !input.hasActiveItem {
      rows.append(
        .init(
          id: .backgroundTask,
          content: .backgroundTask(waitingDescription),
          estimatedHeight: 32
        ))
    }
    if let name = input.waitingHarnessUpdateName, input.activityMessage == nil {
      rows.append(.init(id: .updateGate, content: .updateGate(name), estimatedHeight: 32))
    }
    if (!settled.isEmpty || input.hasActiveItem), let message = input.serverWaitMessage, input.activityMessage == nil {
      rows.append(.init(id: .serverWait, content: .serverWait(message), estimatedHeight: 32))
    }
  }

  private static func appendActivityAndErrors(
    _ input: TranscriptProjectionInput,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if let message = input.activityMessage {
      rows.append(
        .init(
          id: .connecting, content: .connecting(message), estimatedHeight: 32,
          measurementRevision: message.hashValue))
    }
    if let message = input.sessionErrorMessage {
      rows.append(.init(id: .error, content: .error(message), estimatedHeight: 56))
    }
    if case let .failed(message) = input.status,
      message != input.sessionErrorMessage
    {
      rows.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
    }
  }

  private static func appendBottomSpacer(
    _ options: TranscriptProjectionOptions,
    to rows: inout [TranscriptPresentationRow]
  ) {
    if let requestedHeight = options.bottomSpacerHeight {
      let height = max(1, requestedHeight)
      rows.append(
        .init(
          id: .bottomSpacer,
          content: .bottomSpacer(height),
          estimatedHeight: height
        ))
    }
  }

  private static func appendOptimisticMessage(
    _ message: UserMessage,
    to rows: inout [TranscriptPresentationRow]
  ) {
    rows.append(
      .init(
        id: .message(message.id),
        content: .optimistic(message),
        estimatedHeight: 90,
        measurementRevision: TranscriptAssistantRowProjection.optimisticMeasurementRevision(
          for: message
        )
      ))
  }

  private static func appendSetupPhases(
    _ phases: [SessionSetupPhase],
    to rows: inout [TranscriptPresentationRow]
  ) {
    rows.append(
      .init(
        id: .setup,
        content: .setup(phases),
        estimatedHeight: 80
      ))
  }
}
