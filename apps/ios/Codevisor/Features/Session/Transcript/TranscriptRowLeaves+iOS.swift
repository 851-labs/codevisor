import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit
import UIKit

extension TranscriptRowLeaves {
  @MainActor
  static func iOS(controller: SessionController) -> TranscriptRowLeaves {
    TranscriptRowLeaves(
      conversationItem: { item, isWaitingOnUser, waitingOnBackgroundTask, goalActivity in
        AnyView(
          ConversationItemRow(
            item: item,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            goalActivity: goalActivity
          ))
      },
      activeConversationItem: { item, isWaitingOnUser, waitingOnBackgroundTask, goalActivity, _ in
        AnyView(
          ConversationItemRow(
            item: item,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            goalActivity: goalActivity
          ))
      },
      assistantTurn: { message, isWaitingOnUser, waitingOnBackgroundTask, presentation in
        AnyView(
          AssistantTurnBody(
            turn: message.turn,
            turnId: message.id,
            isWaitingOnUser: isWaitingOnUser,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            presentation: presentation
          ))
      },
      userMessage: { message in
        AnyView(AttributedUserMessage(message) { UserBubbleRow(text: message.text, attachments: message.attachments) })
      },
      botMessage: { message, content in
        AnyView(BotBubbleRow(id: message.id, content: content))
      },
      workedItem: { item, _, turnID, isTurnActive, animationPresentation, animationEnabled in
        AnyView(
          TurnItemsView(
            items: [item],
            turnId: turnID,
            isTurnActive: isTurnActive,
            animationPresentation: animationPresentation,
            animationEnabled: animationEnabled
          ))
      },
      attachmentThumbnail: { file in
        AnyView(AttachmentThumbnailView(file: file))
      },
      setup: { phases in
        AnyView(SessionSetupView(phases: phases))
      },
      setupRequest: setupRequestRow,
      interaction: questionRow,
      errorRow: { message, rowID in
        AnyView(SessionErrorRow(controller: controller, message: message, rowID: rowID))
      }
    )
  }

  @MainActor
  private static func setupRequestRow(
    _ request: TranscriptSetupRequest, _ inBotConversation: Bool, _ controller: SessionController
  ) -> AnyView {
    AnyView(SetupRequestRow(request: request, inBotConversation: inBotConversation, controller: controller))
  }

  @MainActor
  private static func questionRow(
    _ interaction: TranscriptInteraction, _ inBotConversation: Bool, _ controller: SessionController
  ) -> AnyView {
    AnyView(
      TranscriptQuestionRow(interaction: interaction, inBotConversation: inBotConversation, controller: controller))
  }
}

private struct SessionErrorRow: View {
  let controller: SessionController
  let message: String
  let rowID: TranscriptVirtualRow.ID

  var body: some View {
    if rowID == .statusError, message == controller.projectCloneFailureMessage {
      ProjectCloneFailureNotice(
        projectName: controller.projectClone?.plan.projectName ?? controller.project.name,
        message: message,
        offersSignIn: controller.projectCloneFailureOffersSignIn,
        inBotConversation: controller.presentsBotConversation,
        retry: controller.retryProjectClone,
        signIn: controller.signInForProjectClone
      )
    } else if rowID == .statusError {
      ChatErrorRow(
        message,
        actionTitle: "Retry",
        action: { Task { await controller.retry() } }
      )
    } else if controller.errorRequiresHarnessAuthentication {
      ChatErrorRow(
        message,
        actionTitle: "Sign In",
        action: { [weak controller] in
          guard let controller,
            let harnessId = controller.selectedHarnessId ?? controller.activeHarnessId
          else { return }
          HarnessSignInRequest(
            serverId: controller.project.serverId, harnessId: harnessId
          ).post()
        }
      )
    } else {
      ChatErrorRow(
        message,
        actionTitle: "Retry",
        action: { Task { await controller.retrySessionFailure() } }
      )
    }
  }
}
