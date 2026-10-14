import CodevisorProtocol

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
    let hasLiveWorkedHeader = rows.contains { row in
      guard case .header? = row.workedSection?.role, let kind = row.workedSection?.identity.kind
      else { return false }
      return message.turn.workedSectionTicks(kind)
    }
    if !hasLiveWorkedHeader {
      appendActivityIfNeeded(message, lifecycle: lifecycle, to: &rows)
    }
    appendStopDetailEpilogueIfNeeded(
      message,
      waitingOnBackgroundTask: waitingOnBackgroundTask,
      lifecycle: lifecycle,
      to: &rows
    )
    return projectedContent || !rows.isEmpty ? rows : [activeFallbackRow(for: item)]
  }
}
