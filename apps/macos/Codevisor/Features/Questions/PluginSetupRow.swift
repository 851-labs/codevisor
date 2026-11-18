import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct PluginSetupRow: View {
  @Environment(AppEnvironment.self) private var environment
  let setup: TranscriptPluginSetup
  let request: ServerPluginSetupRequest
  let inBotConversation: Bool
  let controller: SessionController

  var body: some View {
    PluginSetupHost(
      request: request,
      isConnected: setup.state == .connected,
      machineId: controller.project.serverId,
      client: environment.machines.client(for: controller.project.serverId),
      signInRoute: signInRoute,
      inBotConversation: inBotConversation
    ) { editing, accounts in
      PluginAccountEditorSheet(editing: editing, model: accounts)
    } guideSheet: { guide, onSaved in
      PluginAccountGuideSetupSheet(model: guide, onSaved: onSaved)
    }
  }

  private var signInRoute: PluginSignInRoute {
    let local = CodevisorMachine.local.id
    return controller.project.serverId == local ? .thisMachine : .localMachine(environment.machines.client(for: local))
  }
}
