import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

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
        action: openHarnessAccounts
      )
    } else {
      ChatErrorRow(
        message,
        actionTitle: "Retry",
        action: { Task { await controller.retrySessionFailure() } }
      )
    }
  }

  private func openHarnessAccounts() {
    if let harnessId = controller.selectedHarnessId ?? controller.activeHarnessId {
      SettingsRouter.shared.showHarnessAccounts(machineId: controller.project.serverId, harnessId: harnessId)
    } else {
      SettingsRouter.shared.showHarnesses()
    }
    openSettings()
  }
}
