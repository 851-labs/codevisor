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
    let projectedContent = appendAssistantBlocks(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    )
    appendActivityIfNeeded(message, lifecycle: lifecycle, to: &rows)
    // A failed turn stays in the active slot until the next bubble starts,
    // and the session-level banner defers to it. Without this row the
    // failure either never appeared (turns with worked items) or was
    // drawn in place into the aggregate row's 32pt "Waiting on harness"
    // frame and clipped to a sliver until a remeasure landed.
    appendStopDetailEpilogueIfNeeded(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    )
    return projectedContent || !rows.isEmpty ? rows : [activeFallbackRow(for: item)]
  }
}
