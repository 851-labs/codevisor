import CodevisorCore
import CodevisorUI
import SwiftUI

struct SetupRequestRow: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let request: TranscriptSetupRequest
  let inBotConversation: Bool
  let controller: SessionController

  var body: some View {
    TranscriptSetupRequestCard(
      request: request,
      inBotConversation: inBotConversation,
      handoffMachineName: environment?.machines.machine(for: controller.project.serverId)?.name ?? "the Mac",
      onSetUp: {},
      onDecline: { Task { await controller.declineSetupRequest(request.id) } }
    )
  }
}
