import CodevisorCore
import Foundation
import TranscriptKit

extension TranscriptSendAnimationContract {
  /// Setup and connection progress are separate from the assistant's
  /// active rows. Keep those ephemeral states behind the same send gate,
  /// including a status row mounted before the send request was published.
  /// The native hold preserves its measured space until the bubble lands.
  public static func shouldHoldAssistantRow(
    phase: TranscriptSendPresentationPhase,
    rowID: TranscriptPresentationRow.ID,
    rowExistedBeforeSend: Bool
  ) -> Bool {
    switch rowID {
    case .setup, .backgroundTask, .updateGate, .connecting, .serverWait:
      return phase != .idle
    default:
      return shouldHoldAssistantRow(
        phase: phase,
        rowIsActive: rowID.isActiveRow,
        rowExistedBeforeSend: rowExistedBeforeSend
      )
    }
  }

  /// Whether a projected row can be the destination of a send flight.
  /// An optimistic send lands on the optimistic user bubble; a flight into
  /// an active turn lands on the settled user message that started it.
  public static func isEligibleTarget(
    _ row: TranscriptPresentationRow,
    for destination: UserSendAnimationDestination
  ) -> Bool {
    switch destination {
    case .optimistic:
      return row.isUserMessage
    case .activeTurn:
      guard case let .message(item, waitingOnBackgroundTask: _) = row.content,
        case .user = item
      else { return false }
      return true
    }
  }
}
