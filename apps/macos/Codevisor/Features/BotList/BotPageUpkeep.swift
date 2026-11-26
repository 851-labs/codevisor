import CodevisorCore
import SwiftUI

struct BotPageFocusRequest: Equatable {
  let id = UUID()
  let workspaceId: UUID
}

struct BotPageUpkeep: ViewModifier {
  let workspace: Workspace
  let store: SessionStore
  let focusPage: () -> Void
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .onChange(of: store.botPageFocusRequest) { _, request in
        if request?.workspaceId == workspace.id { focusPage() }
      }
      .onChange(of: botWithGoneAgent, initial: true) { _, bot in
        if let bot { environment.botPages.forgetGoneAgent(of: bot) }
      }
  }

  private var botWithGoneAgent: Bot? {
    guard let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId),
      environment.botPages.hasGoneAgent(bot)
    else { return nil }
    return bot
  }
}
