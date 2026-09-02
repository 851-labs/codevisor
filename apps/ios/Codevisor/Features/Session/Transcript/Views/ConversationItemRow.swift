import CodevisorUI
import ACPKit
import SwiftUI
import TranscriptKit

/// One conversation item: a trailing user bubble or a complete assistant turn.
struct ConversationItemRow: View {
    let item: ConversationItem
    var isWaitingOnUser = false
    var waitingOnBackgroundTask: String? = nil
    var goalActivity: GoalActivity? = nil

    var body: some View {
        switch item {
        case let .user(message):
            UserBubbleRow(text: message.text, attachments: message.attachments)
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
