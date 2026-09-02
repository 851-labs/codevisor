import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

extension TranscriptRowLeaves {
  /// The AppKit row views. `errorRow` stays with the chat screen because its
  /// sign-in action drives screen state.
  @MainActor
  static func macOS(
    errorRow: @escaping (String) -> AnyView
  ) -> TranscriptRowLeaves {
    TranscriptRowLeaves(
      conversationItem: { item, isWaitingOnUser, waitingOnBackgroundTask, goalActivity in
        AnyView(
          ConversationItemView(
            item: item,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            goalActivity: goalActivity
          ))
      },
      activeConversationItem: { item, isWaitingOnUser, waitingOnBackgroundTask, goalActivity, controller in
        AnyView(
          ConversationItemView(
            item: item,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            goalActivity: goalActivity
          )
          // The outer active-row host's environment is frozen from
          // when streaming began. Refresh hover suspension here so
          // copy affordances wake up as soon as the turn ends into
          // a background-task wait.
          .environment(\.hoverTrackingSuspended, controller.isSending))
      },
      assistantTurn: { message, isWaitingOnUser, waitingOnBackgroundTask, presentation in
        AnyView(
          AssistantTurnView(
            turn: message.turn,
            turnID: message.id,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            presentation: presentation
          ))
      },
      userMessage: { message in
        AnyView(UserMessageView(message: message))
      },
      workedItem: { item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
        AnyView(
          TranscriptItemsView(
            items: [item],
            turn: turn,
            turnID: turnID,
            isTurnActive: isTurnActive,
            animationPresentation: animationPresentation,
            animationEnabled: animationEnabled
          ))
      },
      attachmentThumbnail: { file in
        AnyView(AttachmentThumbnailView(file: file, inline: true))
      },
      setup: { phases in
        AnyView(SessionSetupView(phases: phases))
      },
      errorRow: { message, _ in
        errorRow(message)
      }
    )
  }
}
