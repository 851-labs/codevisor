import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

// MARK: - RowContent

extension ChatScreen {
  var rowLeaves: TranscriptRowLeaves {
    .macOS(errorRow: { AnyView(errorBanner($0)) })
  }

  @ViewBuilder
  func errorBanner(_ message: String) -> some View {
    if message == serverUnreachableErrorMessage {
      ChatErrorRow(
        message,
        actionTitle: "Restart",
        action: { AppRelauncher.relaunch() }
      )
    } else if controller.errorRequiresHarnessAuthentication {
      ChatErrorRow(
        message,
        actionTitle: "Sign In",
        action: {
          authSignInHarnessId = controller.selectedHarnessId ?? controller.activeHarnessId
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
