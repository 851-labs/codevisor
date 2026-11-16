import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarBotsEmptyState: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let onNewBot: () -> Void

  var body: some View {
    BotsEmptyState(serverId: serverId, onNewBot: onNewBot)
  }

  private var serverId: String {
    environment?.defaultComposerServerId ?? CodevisorMachine.local.id
  }
}
