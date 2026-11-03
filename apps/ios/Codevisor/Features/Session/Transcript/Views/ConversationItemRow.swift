import CodevisorUI
import ACPKit
import SwiftUI
import TranscriptKit

struct ConversationItemRow: View {
  let item: ConversationItem
  var isWaitingOnUser = false
  var waitingOnBackgroundTask: String? = nil
  var goalActivity: GoalActivity? = nil

  var body: some View {
    switch item {
    case let .user(message) where message.isEvent:
      EmptyView()
    case let .user(message):
      UserBubbleRow(message: message)
    case let .assistant(message):
      AssistantTurnBody(
        turn: message.turn,
        turnId: message.id,
        isWaitingOnUser: isWaitingOnUser,
        waitingOnBackgroundTask: waitingOnBackgroundTask,
        goalActivity: goalActivity,
        presentation: .complete
      )
    }
  }
}
