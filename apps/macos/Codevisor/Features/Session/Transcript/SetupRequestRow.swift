import CodevisorCore
import CodevisorUI
import SwiftUI

struct SetupRequestRow: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let request: TranscriptSetupRequest
  let inBotConversation: Bool
  let controller: SessionController

  private var handoffMachineName: String? {
    let serverId = controller.project.serverId
    guard serverId != CodevisorMachine.local.id else { return nil }
    return environment?.machines.machine(for: serverId)?.name ?? "the Mac running this chat"
  }

  var body: some View {
    TranscriptSetupRequestCard(
      request: request,
      inBotConversation: inBotConversation,
      handoffMachineName: handoffMachineName,
      onSetUp: { controller.presentedSetupRequest = request },
      onDecline: { Task { await controller.declineSetupRequest(request.id) } }
    )
  }
}
