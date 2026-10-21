import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

extension TranscriptRowLeaves {
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
      botMessage: { message, content in
        AnyView(BotMessageView(message: message, content: content))
      },
      workedItem: { item, _, turnID, isTurnActive, animationPresentation, animationEnabled in
        AnyView(
          TranscriptItemsView(
            items: [item],
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
      setupRequest: { request, inBotConversation, controller in
        AnyView(SetupRequestRow(request: request, inBotConversation: inBotConversation, controller: controller))
      },
      errorRow: { message, _ in
        errorRow(message)
      }
    )
  }
}
