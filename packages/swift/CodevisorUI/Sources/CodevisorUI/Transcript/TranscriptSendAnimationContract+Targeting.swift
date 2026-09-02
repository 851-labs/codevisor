import CodevisorCore
import Foundation
import TranscriptKit

extension TranscriptSendAnimationContract {
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
