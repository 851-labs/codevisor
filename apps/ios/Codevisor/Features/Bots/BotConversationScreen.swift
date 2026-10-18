import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.windowID) private var windowID
  let serverId: String
  let botId: UUID
  let onDeleted: (Bot) -> Void
  @State private var controller: SessionController?
  @State private var editing: BotEditorTarget?
  @State private var deleting: Bot?

  private var bot: Bot? { environment.bots.bot(serverId: serverId, id: botId) }

  private var session: ChatSession? {
    bot.flatMap { environment.projectList.session($0.sessionId, serverId: $0.serverId) }
  }

  var body: some View {
    content
      .navigationTitle(bot?.name ?? "Bot")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarTitleMenu {
        if let bot {
          Button("Edit Bot…", systemImage: "pencil") { editing = .edit(bot) }
          Button("Delete Bot…", systemImage: "trash", role: .destructive) { deleting = bot }
        }
      }
      .botManagement(editing: $editing, deleting: $deleting, onDeleted: onDeleted)
      .task(id: session?.id) { await connect() }
  }

  @ViewBuilder
  private var content: some View {
    if let bot, let controller {
      SessionTranscriptView(
        controller: controller,
        presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
          for: .init(paneID: bot.id, isNewChat: false, windowID: windowID),
          controller: controller
        )
      )
      .id(bot.sessionId)
    } else if bot == nil {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ChatSurfaceBackground().ignoresSafeArea() }
    }
  }

  private func connect() async {
    guard let bot, let session,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return }
    let controller = ChatControllerCache.shared.controller(
      for: session, project: project, workspaceId: bot.workspaceId, environment: environment)
    if bot.isConversational { controller.presentBotConversation() }
    self.controller = controller
    guard controller.model == nil, !controller.isConnecting else { return }
    if session.agentSessionId?.isEmpty != false {
      await controller.prepare()
      controller.applyComposerDefaults()
    }
    await controller.connectIfNeeded()
  }
}
