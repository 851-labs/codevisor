import CodevisorCore
import CodevisorUI
import SwiftUI

struct SetupRequestRow: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let request: TranscriptSetupRequest
  let inBotConversation: Bool
  let controller: SessionController

  private var machineName: String {
    environment?.machines.machine(for: controller.project.serverId)?.name ?? "the Mac running this chat"
  }

  private var handoffMachineName: String? {
    guard controller.project.serverId != CodevisorMachine.local.id else { return nil }
    return machineName
  }

  private var setsUpChromeHere: Bool {
    request.kind == .chromeExtension && handoffMachineName == nil
  }

  var body: some View {
    if setsUpChromeHere {
      ChromeSetupRequestRow(
        request: request, inBotConversation: inBotConversation, machineName: machineName, controller: controller)
    } else {
      TranscriptSetupRequestCard(
        request: request,
        inBotConversation: inBotConversation,
        handoffMachineName: handoffMachineName,
        machineName: machineName,
        onSetUp: { controller.presentedSetupRequest = request },
        onDecline: { Task { await controller.declineSetupRequest(request.id) } }
      )
    }
  }
}
