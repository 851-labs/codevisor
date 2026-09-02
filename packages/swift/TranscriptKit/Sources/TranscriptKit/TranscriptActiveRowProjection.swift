import CodevisorProtocol

/// Builds only the live transcript slice. Callers can parse this snapshot off
/// the UI actor and splice it over the projection cache's single active slot,
/// leaving the settled transcript untouched on token flushes.
public enum TranscriptActiveRowProjection {
  public static func rows(
    for item: ConversationItem,
    waitingOnBackgroundTask: String? = nil
  ) -> [TranscriptPresentationRow] {
    TranscriptAssistantRowProjection.activeRows(
      for: item,
      waitingOnBackgroundTask: waitingOnBackgroundTask
    )
  }

  public static func replacingActiveSlot(
    in rows: [TranscriptPresentationRow],
    with activeRows: [TranscriptPresentationRow]
  ) -> [TranscriptPresentationRow] {
    guard !activeRows.isEmpty,
      let activeIndex = rows.firstIndex(where: { $0.id.isActiveRow }),
      case let .active(activeMessageID) = rows[activeIndex].id,
      activeRows.first?.id.messageID == activeMessageID
    else { return rows }
    var result = rows
    result.replaceSubrange(activeIndex...activeIndex, with: activeRows)
    return result
  }
}

extension TranscriptAssistantRowProjection {
  static func activeRows(
    for item: ConversationItem,
    waitingOnBackgroundTask: String?
  ) -> [TranscriptPresentationRow] {
    guard case let .assistant(message) = item else { return [activeFallbackRow(for: item)] }

    var rows: [TranscriptPresentationRow] = []
    let lifecycle: TranscriptBlockLifecycle =
      message.turn.isGenerating ? .receiving : .settled
    var projectedContent = TranscriptAssistantRowProjection.appendWorkedSection(
      message,
      kind: .planning,
      items: message.turn.workedItemsBeforePlan,
      showsTimer: message.turn.planBoundary == nil,
      allowsDeferred: true,
      lifecycle: lifecycle,
      to: &rows
    )
    if let planDocument = message.turn.planDocument, !planDocument.isEmpty {
      TranscriptPlanRowProjection.append(
        messageID: message.id,
        markdown: planDocument,
        lifecycle: lifecycle,
        to: &rows
      )
      projectedContent = true
      projectedContent =
        appendWorkedSection(
          message,
          kind: .implementation,
          items: message.turn.workedItemsAfterPlan,
          showsTimer: true,
          allowsDeferred: false,
          lifecycle: lifecycle,
          to: &rows
        ) || projectedContent
      projectedContent =
        appendAssistantResponse(
          message,
          waitingOnBackgroundTask: waitingOnBackgroundTask,
          lifecycle: lifecycle,
          to: &rows
        ) || projectedContent
      appendActivityIfNeeded(message, lifecycle: lifecycle, to: &rows)
      return projectedContent || !rows.isEmpty ? rows : [activeFallbackRow(for: item)]
    }

    projectedContent =
      appendAssistantResponse(
        message,
        waitingOnBackgroundTask: waitingOnBackgroundTask,
        lifecycle: lifecycle,
        to: &rows
      ) || projectedContent
    appendActivityIfNeeded(message, lifecycle: lifecycle, to: &rows)
    return projectedContent || !rows.isEmpty ? rows : [activeFallbackRow(for: item)]
  }
}
