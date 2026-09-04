import Foundation

extension TranscriptRowSet {
  /// Server identity adoption and the aggregate-to-block projection can
  /// replace an unchanged waiting row under a new layout key. Carry its
  /// measured height through both transitions instead of briefly restoring
  /// the activity estimate. Call only within the same layout fingerprint;
  /// activating a different width cache discards these heights as usual.
  public static func preserveWaitingActivityHeight(
    from oldRows: [Row],
    to newRows: [Row],
    ledger: inout TranscriptMeasurementLedger
  ) {
    guard let old = waitingActivity(in: oldRows),
      let new = waitingActivity(in: newRows),
      old.promptID == new.promptID,
      old.turn == new.turn,
      old.row.spacingAfter == new.row.spacingAfter,
      old.row.layoutKey != new.row.layoutKey,
      let height = ledger[old.row.layoutKey],
      !ledger.isStale(old.row.layoutKey),
      ledger[new.row.layoutKey] == nil
    else { return }

    // This is the same content at the same width, so the measurement also
    // remains valid if another projection replaces this bridge before its
    // host reports. Active hosts still perform their own fresh measurement.
    ledger.setExact(height, for: new.row.layoutKey)
  }

  private static func waitingActivity(
    in rows: [Row]
  ) -> (row: Row, turn: AssistantTurn, promptID: UUID)? {
    let activeIndices = rows.indices.filter { rows[$0].id.isActiveRow }
    guard activeIndices.count == 1, let index = activeIndices.first else { return nil }
    let row = rows[index]
    let message: AssistantMessage
    switch row.content {
    case let .assistantChrome(assistant, slice: .activity, waitingOnBackgroundTask: nil):
      message = assistant
    case let .active(.assistant(assistant)):
      message = assistant
    default:
      return nil
    }
    let turn = message.turn
    guard turn.isGenerating, !turn.isThinking, turn.retryStatus == nil,
      turn.entries.isEmpty, turn.attachments.isEmpty, turn.subagents.isEmpty,
      turn.planDocument == nil, !turn.hasDeferredWorkedDetails,
      turn.stopDetail == nil,
      let prompt = rows[..<index].last(where: { $0.isUserMessage }),
      let promptID = prompt.id.messageID
    else { return nil }
    return (row, turn, promptID)
  }
}
