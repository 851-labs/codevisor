import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit
import UIKit

extension TranscriptRowLeaves {
  /// The UIKit row views.
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
        AnyView(UserBubbleRow(text: message.text, attachments: message.attachments))
      },
      workedItem: { item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
        AnyView(
          TurnItemsView(
            items: [item],
            turn: turn,
            turnId: turnID,
            depth: 0,
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
      errorRow: { message, rowID in
        AnyView(SessionErrorRow(controller: controller, message: message, rowID: rowID))
      }
    )
  }
}

/// A status-error row retries the last request; a session error offers sign
/// in when the harness needs authentication, otherwise a session retry.
private struct SessionErrorRow: View {
  let controller: SessionController
  let message: String
  let rowID: TranscriptVirtualRow.ID

  var body: some View {
    if rowID == .statusError {
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
